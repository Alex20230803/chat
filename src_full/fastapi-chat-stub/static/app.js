(() => {
  const uid = () => Math.random().toString(36).slice(2, 10);
  const convsEl = document.getElementById('convs');
  const msgsEl = document.getElementById('msgs');
  const inputEl = document.getElementById('input');
  const newChatBtn = document.getElementById('newChatBtn');
  const sendBtn = document.getElementById('sendBtn');
  const stopBtn = document.getElementById('stopBtn');
  const modeSel = document.getElementById('modeSel');

  let conversations = [];
  let activeId = null;
  let activeEventSource = null;

    // Local persistence helpers (client-side fallback when server DB doesn't return results)
    const LOCAL_KEY = 'local_conversations_v1';
    function loadLocalSessions() {
      try {
        const raw = localStorage.getItem(LOCAL_KEY);
        if (!raw) return [];
        return JSON.parse(raw);
      } catch (e) {
        console.error('failed to load local sessions', e);
        return [];
      }
    }
    function saveLocalSessions(list) {
      try { localStorage.setItem(LOCAL_KEY, JSON.stringify(list)); } catch (e) { console.error('failed to save local sessions', e); }
    }
    function saveLocalSession(session) {
      const list = loadLocalSessions();
      const idx = list.findIndex(s => s.id === session.id);
      if (idx >= 0) list[idx] = session; else list.unshift(session);
      saveLocalSessions(list);
    }
    function saveLocalMessage(sessionId, message) {
      const list = loadLocalSessions();
      const s = list.find(x => x.id === sessionId);
      if (s) { s.messages = s.messages || []; s.messages.push(message); saveLocalSessions(list); }
    }
    function loadLocalMessages(sessionId) {
      const list = loadLocalSessions();
      const s = list.find(x => x.id === sessionId);
      return s && s.messages ? s.messages : [];
    }
  function renderConvs() {
    convsEl.innerHTML = '';
    conversations.forEach(c => {
      const wrap = document.createElement('div');
      wrap.className = 'conv-wrap';
      wrap.style.position = 'relative';

      const btn = document.createElement('button');
      btn.className = 'conv' + (c.id === activeId ? ' active' : '');
      btn.style.width = '100%';
      btn.style.textAlign = 'left';
      btn.innerHTML = `<div class="title">${c.title}</div><div class="muted">${new Date(c.createdAt).toLocaleString()}</div>`;
  btn.onclick = async () => { activeId = c.id; await loadMessages(c.id); syncStagedWithActive(); render(); };

      // Overflow (three-dot) menu
      const menuBtn = document.createElement('button');
      menuBtn.className = 'conv-menu-btn';
      menuBtn.type = 'button';
      menuBtn.innerHTML = '\u22EF'; // midline ellipsis
      menuBtn.title = 'More';
      menuBtn.style.position = 'absolute';
      menuBtn.style.right = '6px';
      menuBtn.style.top = '6px';
      menuBtn.style.background = 'transparent';
      menuBtn.style.border = 'none';
      menuBtn.style.cursor = 'pointer';
      menuBtn.style.fontSize = '18px';

      const menu = document.createElement('div');
      menu.className = 'conv-menu';
      // inline styles so it works without external CSS
      Object.assign(menu.style, {
        position: 'absolute',
        right: '6px',
        top: '32px',
        background: 'white',
        border: '1px solid #ccc',
        padding: '6px',
        display: 'none',
        zIndex: 1000,
        minWidth: '120px',
        boxShadow: '0 2px 6px rgba(0,0,0,0.12)'
      });

      function showMenu() { menu.style.display = 'block'; }
      function hideMenu() { menu.style.display = 'none'; }

      // Menu items
      const miRename = document.createElement('div');
      miRename.textContent = 'Rename';
      miRename.style.padding = '6px';
      miRename.style.cursor = 'pointer';
      miRename.onclick = async (e) => {
        e.stopPropagation(); hideMenu();
        const newTitle = prompt('New title', c.title || '');
        if (!newTitle) return;
        try {
          const res = await authFetch(`/api/sessions/${encodeURIComponent(c.id)}`, { method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ title: newTitle }) });
          if (res.ok) {
            c.title = newTitle;
            saveLocalSession(c);
            render();
          } else {
            console.error('rename failed', await res.text());
          }
        } catch (err) { console.error('rename error', err); }
      };

      const miDelete = document.createElement('div');
      miDelete.textContent = 'Delete';
      miDelete.style.padding = '6px';
      miDelete.style.cursor = 'pointer';
      miDelete.style.color = '#b00';
      miDelete.onclick = async (e) => {
        e.stopPropagation(); hideMenu();
        if (!confirm('Delete this conversation?')) return;
        try {
          const res = await authFetch(`/api/sessions/${encodeURIComponent(c.id)}`, { method: 'DELETE' });
          if (res.ok) {
            conversations = conversations.filter(x => x.id !== c.id);
            const local = loadLocalSessions().filter(x => x.id !== c.id);
            saveLocalSessions(local);
            if (activeId === c.id) activeId = conversations.length ? conversations[0].id : null;
            syncStagedWithActive();
            render();
          } else {
            console.error('delete failed', await res.text());
          }
        } catch (err) { console.error('delete error', err); }
      };

      menu.appendChild(miRename);
      menu.appendChild(miDelete);

  // Previously the menu showed on hover. Change: only open on explicit
  // menu button click. Hover handlers removed so the menu doesn't pop up.

      // Also allow explicit click on menu button to toggle
      menuBtn.addEventListener('click', (e) => { e.stopPropagation(); menu.style.display = (menu.style.display === 'block') ? 'none' : 'block'; });

      wrap.appendChild(btn);
      wrap.appendChild(menuBtn);
      wrap.appendChild(menu);
      convsEl.appendChild(wrap);
    });
  }

  // Close any open conv menus when clicking elsewhere on the document.
  // We attach this once at module init, not inside renderConvs, to avoid
  // adding duplicate listeners on each re-render.
  document.addEventListener('click', () => {
    document.querySelectorAll('.conv-menu').forEach(m => { m.style.display = 'none'; });
  });

  function renderMsgs() {
    const c = conversations.find(x => x.id === activeId);
    msgsEl.innerHTML = '';
    if (!c) return; // nothing to render
    (c.messages || []).forEach(m => {
      const wrap = document.createElement('div');
      wrap.className = 'msg ' + (m.role === 'user' ? 'you' : '');
      const bubble = document.createElement('div');
      bubble.className = 'bubble';
      bubble.textContent = m.content;
      // render any inline attachments URLs inside a message (simple heuristic)
      try {
        if (m.content && m.content.includes(': http')) {
          // replace lines like "name: /uploads/xxx" with link nodes
          const parts = m.content.split('\n');
          bubble.innerHTML = '';
          parts.forEach((p, idx) => {
            const sep = p.indexOf(': ');
            if (sep > 0) {
              const name = p.slice(0, sep).trim();
              const url = p.slice(sep + 2).trim();
              const a = document.createElement('a');
              a.href = url; a.target = '_blank'; a.textContent = name; a.style.color = '#1f6feb';
              bubble.appendChild(a);
            } else {
              bubble.appendChild(document.createTextNode(p));
            }
            if (idx < parts.length - 1) bubble.appendChild(document.createElement('br'));
          });
        }
      } catch(e) { /* ignore render errors */ }
      wrap.appendChild(bubble);
      msgsEl.appendChild(wrap);
    });
    // scroll the messages view to bottom so composer stays visible
    requestAnimationFrame(() => { msgsEl.scrollTop = msgsEl.scrollHeight; });
  }

  function render() { renderConvs(); renderMsgs(); }

  // Keep stagedFiles in sync with the active conversation's attachments.
  function syncStagedWithActive() {
    const c = conversations.find(x => x.id === activeId);
    if (c) {
      stagedFiles = c.attachments ? c.attachments.slice() : [];
    } else {
      stagedFiles = [];
    }
    renderAttached();
  }

  // Load sessions from server and hydrate conversations
  async function loadSessions() {
    try {
      const res = await authFetch('/api/sessions');
      const j = await res.json();
        let serverConvs = [];
        if (j.sessions && Array.isArray(j.sessions)) {
          serverConvs = j.sessions.map(s => ({ id: s.meta_id, title: s.title || 'Новый чат', createdAt: s.created || Date.now(), messages: [] }));
        }
        // Merge with locally persisted sessions. Local attachments (and messages)
        // should be merged into server sessions with the same id so client-side
        // uploads (saved to static/uploads and localStorage) are not lost on reload.
        const local = loadLocalSessions();
        const merged = [];
        const seen = new Set();
        // prefer server order first
        serverConvs.forEach(s => { merged.push(s); seen.add(s.id); });
        // append local-only sessions
        local.forEach(s => { if (!seen.has(s.id)) { merged.push(s); seen.add(s.id); } });
        // merge attachments and any local messages into existing server sessions
        // so attachments uploaded previously are restored after a reload
        for (const loc of local) {
          const idx = merged.findIndex(m => m.id === loc.id);
          if (idx >= 0) {
            // preserve server-side fields, but merge attachments & messages from local
            merged[idx].attachments = loc.attachments || merged[idx].attachments || [];
            // Merge local messages into server messages, avoiding duplicates by role+content
            merged[idx].messages = merged[idx].messages || [];
            const existing = new Set(merged[idx].messages.map(m => `${m.role}:::${(m.content||'').trim()}`));
            if (loc.messages && loc.messages.length) {
              for (const lm of loc.messages) {
                const sig = `${lm.role}:::${lm.content}`;
                if (!existing.has(sig)) {
                  merged[idx].messages.push(lm);
                  existing.add(sig);
                }
              }
              // keep messages roughly time-ordered when createdAt is present
              merged[idx].messages.sort((a, b) => (a.createdAt || 0) - (b.createdAt || 0));
            }
          }
        }
        conversations = merged;
        if (conversations.length > 0) activeId = conversations[0].id;
      // If no sessions exist, create one so UI has an active chat to persist into
      if ((!j.sessions || !j.sessions.length) && !activeId) {
        try {
          const created = await authFetch('/api/sessions', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ title: 'Новый чат' }) });
          const cj = await created.json();
          const id = cj.meta_id || uid();
          const c = { id, title: cj.title || 'Новый чат', createdAt: Date.now(), messages: [] };
          conversations.unshift(c);
          activeId = id;
          saveLocalSession(c);
        } catch (e) { console.error('failed to auto-create session', e); }
      }
      render();
      // load messages for active session and sync attachments
      if (activeId) { await loadMessages(activeId); syncStagedWithActive(); }
    } catch (e) {
      console.error('failed to load sessions', e);
    }
  }

  // Ensure there's an active session; create one if needed
  async function ensureActiveSession() {
    if (activeId) return activeId;
    // if any conversation exists set the first one
    if (conversations.length > 0) {
      activeId = conversations[0].id;
      return activeId;
    }
    try {
      const res = await authFetch('/api/sessions', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ title: 'Новый чат' }) });
      const j = await res.json();
      const id = j.meta_id || uid();
      const c = { id, title: j.title || 'Новый чат', createdAt: Date.now(), messages: [] };
      conversations.unshift(c);
      activeId = id;
      render();
      syncStagedWithActive();
      return activeId;
    } catch (e) {
      console.error('failed to ensure active session', e);
      return null;
    }
  }

  async function loadMessages(sessionId) {
    try {
      const res = await authFetch(`/api/sessions/${encodeURIComponent(sessionId)}/messages`);
      const j = await res.json();
      const c = conversations.find(x => x.id === sessionId);
      if (!c) return;
        // prefer server messages when available, otherwise fall back to local messages
        if (j.messages && Array.isArray(j.messages) && j.messages.length) {
          c.messages = (j.messages || []).map(m => ({ id: m.meta_id || uid(), role: m.role, content: m.content, createdAt: Date.now() }));
          // Merge in any local-only messages (e.g. a file-link message saved locally but not yet on server)
          try {
            const localMsgs = loadLocalMessages(sessionId) || [];
            if (localMsgs && localMsgs.length) {
              const exist = new Set(c.messages.map(m => `${m.role}:::${(m.content||'').trim()}`));
              for (const lm of localMsgs) {
                const sig = `${lm.role}:::${lm.content}`;
                if (!exist.has(sig)) { c.messages.push(lm); exist.add(sig); }
              }
              c.messages.sort((a, b) => (a.createdAt || 0) - (b.createdAt || 0));
            }
          } catch (e) { console.error('failed to merge local messages', e); }
        } else {
          c.messages = loadLocalMessages(sessionId) || [];
        }
        // ensure persisted local copy contains messages
        // Also merge any locally-staged attachments so client uploads are not lost when switching dialogs
        try {
          const localList = loadLocalSessions();
          const localSession = localList.find(s => s.id === sessionId);
          if (localSession && localSession.attachments && localSession.attachments.length) {
            c.attachments = c.attachments || [];
            const exist = new Set(c.attachments.map(a => `${a.name}:::${a.url}`));
            for (const la of localSession.attachments) {
              const sig = `${la.name}:::${la.url}`;
              if (!exist.has(sig)) { c.attachments.push(la); exist.add(sig); }
            }
          }
        } catch (e) { console.error('failed to merge local attachments', e); }

        saveLocalSession(c);
      // ensure composer staged files reflect conversation attachments
      try {
        stagedFiles = (c.attachments || []).slice();
      } catch (e) { stagedFiles = []; }
      render();
    } catch (e) { console.error('failed to load messages', e); }
  }

  async function sendJson(prompt) {
    const res = await authFetch(`/api/chat?prompt=${encodeURIComponent(prompt)}`);
    const json = await res.json();
    const text = json.content;
    appendAssistant(text);
    // persist assistant reply
    if (activeId) {
      await authFetch(`/api/sessions/${encodeURIComponent(activeId)}/messages`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ role: 'assistant', content: text })
      });
        // save locally as a fallback so it shows after reload
        saveLocalMessage(activeId, { id: Math.random().toString(36).slice(2,10), role: 'assistant', content: text, createdAt: Date.now() });
    }
  }

  function sendSse(prompt) {
  // For SSE we cannot modify headers easily; include token in query param
  const token = localStorage.getItem('auth_token');
  const qp = token ? `&token=${encodeURIComponent(token)}` : '';
  const url = `/api/chat/stream?prompt=${encodeURIComponent(prompt)}&delay_ms=20${qp}`;
  const es = new EventSource(url);
    activeEventSource = es;
  const id = appendAssistant('');

    es.onmessage = (e) => {
      const el = document.querySelector(`[data-mid="${id}"]`);
      if (!el) return;
      el.textContent += e.data;
      msgsEl.scrollTop = msgsEl.scrollHeight;
    };
    es.addEventListener('done', async () => { es.close(); activeEventSource = null; 
      // persist assistant final content
      const el = document.querySelector(`[data-mid="${id}"]`);
      const text = el ? el.textContent : null;
      if (text && activeId) {
        try {
          await authFetch(`/api/sessions/${encodeURIComponent(activeId)}/messages`, {
            method: 'POST', headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ role: 'assistant', content: text })
          });
            // also save locally as fallback
            saveLocalMessage(activeId, { id: Math.random().toString(36).slice(2,10), role: 'assistant', content: text, createdAt: Date.now() });
        } catch(e){ console.error('failed to persist assistant message', e); }
      }
    });
    es.onerror = () => { es.close(); activeEventSource = null; };
  }

  function appendUser(text) {
    const c = conversations.find(x => x.id === activeId);
    if (!c) return;
    const msg = { id: uid(), role: 'user', content: text, createdAt: Date.now() };
    c.messages.push(msg);
    renderMsgs();
    // persist user message
    (async () => {
      try {
        await authFetch(`/api/sessions/${encodeURIComponent(activeId)}/messages`, {
          method: 'POST', headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ role: 'user', content: text })
        });
          // also save locally
          saveLocalMessage(activeId, msg);
      } catch (e) { console.error('failed to persist user message', e); }
    })();
  }

  function appendAssistant(text) {
    let c = conversations.find(x => x.id === activeId);
    const id = uid();
    if (!c) {
      // No active conversation found — create a temporary one so the UI doesn't crash.
      c = { id: id + '-tmp', title: 'Новый чат', createdAt: Date.now(), messages: [] };
      conversations.unshift(c);
      activeId = c.id;
        // persist this temporary session locally so reloads keep it
        saveLocalSession(c);
        syncStagedWithActive();
    }
    c.messages = c.messages || [];
    c.messages.push({ id, role: 'assistant', content: text, createdAt: Date.now() });
      // save locally so assistant text is available after reload
      saveLocalMessage(activeId, { id, role: 'assistant', content: text, createdAt: Date.now() });
    renderMsgs();
    const bubbles = msgsEl.querySelectorAll('.bubble');
    const last = bubbles[bubbles.length - 1];
    if (last && last.parentElement) last.parentElement.setAttribute('data-mid', id);
    if (last) last.setAttribute('data-mid', id);
    return id;
  }

  function stop() { if (activeEventSource) { activeEventSource.close(); activeEventSource = null; } }

  // --- Auth helpers and login UI wiring ---
  function showLogin(message) {
    const modal = document.getElementById('loginModal');
    document.getElementById('loginMsg').textContent = message || '';
    modal.style.display = 'flex';
  }

  function hideLogin() { document.getElementById('loginModal').style.display = 'none'; }

  async function authFetch(url, opts={}) {
    opts.headers = opts.headers || {};
    const token = localStorage.getItem('auth_token');
    if (token) opts.headers['Authorization'] = `Bearer ${token}`;
    return fetch(url, opts);
  }

  document.getElementById('loginBtn').onclick = async () => {
    const u = document.getElementById('loginUser').value;
    const p = document.getElementById('loginPass').value;
    if (!u || !p) { document.getElementById('loginMsg').textContent = 'Введите логин и пароль'; return; }
    try {
      const res = await fetch('/api/login', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ username: u, password: p }) });
      const j = await res.json();
      localStorage.setItem('auth_token', j.token);
      hideLogin();
    } catch (err) {
      document.getElementById('loginMsg').textContent = 'Ошибка входа';
    }
  };

  document.getElementById('loginGoogle').onclick = () => {
    // Start OAuth simulated flow
    window.location.href = '/api/auth/google';
  };

  // If query param google_auth=1 is present, simulate receiving a token
  (function handleGoogleReturn(){
    try {
      const qp = new URLSearchParams(window.location.search);
      if (qp.get('google_auth') === '1') {
        // fake token for demo
        const token = 'google-demo-' + Math.random().toString(36).slice(2,8);
        localStorage.setItem('auth_token', token);
        // remove the query param from URL
        window.history.replaceState({}, document.title, window.location.pathname);
        hideLogin();
      }
    } catch(e){}
  })();

  // show login on first visit if no token
  if (!localStorage.getItem('auth_token')) showLogin();

  newChatBtn.onclick = async () => {
    try {
      const res = await authFetch('/api/sessions', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ title: 'Новый чат' }) });
      const j = await res.json();
      const id = j.meta_id || uid();
      const c = { id, title: j.title || 'Новый чат', createdAt: Date.now(), messages: [] };
      conversations.unshift(c);
      activeId = c.id;
      render();
      syncStagedWithActive();
    } catch (e) {
      console.error('failed to create session', e);
    }
  };

  // --- File attach / drag & drop support ---
  const attachBtn = document.getElementById('attachBtn');
  const fileInput = document.getElementById('fileInput');
  const attachedFilesEl = document.getElementById('attachedFiles');
  let stagedFiles = []; // {name, url}

  function renderAttached() {
    attachedFilesEl.innerHTML = '';
    stagedFiles.forEach((f, i) => {
      const wrap = document.createElement('div');
      wrap.style.display = 'flex';
      wrap.style.alignItems = 'center';
      wrap.style.padding = '4px 6px';
      wrap.style.border = '1px solid #e5e7eb';
      wrap.style.borderRadius = '8px';
      wrap.style.background = '#fff';
      wrap.style.fontSize = '12px';
      wrap.style.marginBottom = '6px';

      const a = document.createElement('a');
      a.textContent = f.name;
      a.href = f.url || '#';
      a.target = '_blank';
      a.style.color = '#1f6feb';
      a.style.textDecoration = 'none';
      a.style.flex = '1';
      a.style.overflow = 'hidden';
      a.style.whiteSpace = 'nowrap';
      a.style.textOverflow = 'ellipsis';
      if (f.url) a.setAttribute('download', '');

      const rem = document.createElement('button');
      rem.textContent = '✕';
      rem.style.marginLeft = '8px';
      rem.style.border = 'none';
      rem.style.background = 'transparent';
      rem.style.cursor = 'pointer';
      rem.title = 'Remove attached file';
      rem.onclick = () => {
        stagedFiles.splice(i,1);
        // also update conversation attachments and persist locally
        const c = conversations.find(x => x.id === activeId);
        if (c) { c.attachments = stagedFiles.slice(); saveLocalSession(c); }
        renderAttached();
      };

      wrap.appendChild(a);
      wrap.appendChild(rem);
      attachedFilesEl.appendChild(wrap);
    });
  }

  attachBtn.onclick = () => fileInput.click();
  fileInput.addEventListener('change', async (e) => {
    const files = Array.from(e.target.files || []);
    if (!files.length) return;
    // upload files
    for (const f of files) {
      try {
        const body = await f.arrayBuffer();
        const res = await authFetch(`/api/uploads`, { method: 'POST', body: body, headers: { 'X-Filename': f.name } });
        if (res.ok) {
          const j = await res.json();
          stagedFiles.push({ name: f.name, url: j.url });
          // attach to active conversation and persist locally
          const c = conversations.find(x => x.id === activeId);
          if (c) { c.attachments = c.attachments || []; c.attachments.push({ name: f.name, url: j.url }); saveLocalSession(c); }
        } else {
          console.error('upload failed', await res.text());
        }
      } catch (err) { console.error('upload error', err); }
    }
    renderAttached();
    fileInput.value = '';
  });

  // Drag & drop onto the composer area (textarea container)
  const composer = document.querySelector('.composer');
  composer.addEventListener('dragover', (e) => { e.preventDefault(); composer.style.outline = '2px dashed #3b82f6'; });
  composer.addEventListener('dragleave', (e) => { composer.style.outline = 'none'; });
  composer.addEventListener('drop', async (e) => {
    e.preventDefault(); composer.style.outline = 'none';
    const dt = e.dataTransfer;
    if (!dt) return;
    const files = Array.from(dt.files || []);
    for (const f of files) {
      try {
        const body = await f.arrayBuffer();
        const res = await authFetch(`/api/uploads`, { method: 'POST', body: body, headers: { 'X-Filename': f.name } });
        if (res.ok) {
          const j = await res.json();
          stagedFiles.push({ name: f.name, url: j.url });
          const c = conversations.find(x => x.id === activeId);
          if (c) { c.attachments = c.attachments || []; c.attachments.push({ name: f.name, url: j.url }); saveLocalSession(c); }
        } else {
          console.error('upload failed', await res.text());
        }
      } catch (err) { console.error('upload error', err); }
    }
    renderAttached();
  });


    sendBtn.onclick = async () => {
    const raw = inputEl.value || '';
    const prompt = raw.trim();
    // allow sending when there is text OR when there are staged files
    if (!prompt && !(stagedFiles && stagedFiles.length)) return;
    // Ensure we have a session to persist into
    await ensureActiveSession();
    const c = conversations.find(x => x.id === activeId);

    // If there is text, treat as normal user input
    if (prompt) {
      appendUser(prompt);
    }

    // If there are attached files, send them as a user message (even if prompt is empty)
    if (stagedFiles && stagedFiles.length && activeId) {
      const fileText = stagedFiles.map(f => `${f.name}: ${f.url}`).join('\n');
      // create and push a local message so it appears immediately
      try {
        const localMsg = { id: Math.random().toString(36).slice(2,10), role: 'user', content: fileText, createdAt: Date.now() };
        if (c) { c.messages = c.messages || []; c.messages.push(localMsg); saveLocalMessage(activeId, localMsg); renderMsgs(); }
        // persist on server
        await authFetch(`/api/sessions/${encodeURIComponent(activeId)}/messages`, {
          method: 'POST', headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ role: 'user', content: fileText })
        });
      } catch (e) { console.error('failed to persist file refs', e); }
      // clear staged files after sending and persist that change in the session
      if (c) { c.attachments = []; saveLocalSession(c); }
      stagedFiles = [];
      renderAttached();
    }

    inputEl.value = '';
    const finalPrompt = prompt || '';
    (modeSel.value === 'sse') ? sendSse(finalPrompt) : sendJson(finalPrompt);
  };

  stopBtn.onclick = stop;

  inputEl.addEventListener('keydown', (e) => {
    if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); sendBtn.click(); }
  });

  // initial load
  loadSessions();
})();