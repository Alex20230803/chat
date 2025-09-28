import asyncio
import os
import time
import uuid
from typing import Optional

from fastapi import FastAPI, Request, Header, HTTPException, status, UploadFile, File
from fastapi.responses import StreamingResponse, RedirectResponse, JSONResponse
from fastapi import APIRouter
import hashlib
from fastapi.staticfiles import StaticFiles
import logging
import sys
from pydantic import BaseModel

# Import DB objects via absolute import to be robust when the module is
# loaded in different contexts (uvicorn, python -m, tests, etc.).
# DB integration is available under `app.db`, but importing it here forces
# SQLAlchemy and DB drivers to be present at module import time. The chat
# stub doesn't need DB objects for basic operation, so don't import them
# at top-level to keep the app runnable without SQL deps.

# Ensure basic logging is configured so module loggers emit to the server output
logging.basicConfig(level=logging.INFO)

app = FastAPI(title="Chat Stub API")

# Simple in-memory session store for demo purposes. Keys are opaque tokens.
app.state.sessions = {}

# No default mock here: prefer real DB repositories when available. The
# startup handler will attempt to import and attach real repos; if DB
# deps are missing we keep `app.state.repos` unset and log a warning.


@app.on_event("startup")
async def load_db_repos():
    """Lazily import DB repositories at startup so the app can still run
    without SQLAlchemy installed for simple testing. If DB deps exist,
    attach them to `app.state` for handlers to use.
    """
    logger = logging.getLogger("chatstub.startup")
    try:
        from app.db.db import DB, PROMPTS, LLMS, PCACHES, USER_DOCS, AGENT_SK, CHAT
        app.state.DB = DB
        app.state.repos = {
            "PROMPTS": PROMPTS,
            "LLMS": LLMS,
            "PCACHES": PCACHES,
            "USER_DOCS": USER_DOCS,
            "AGENT_SK": AGENT_SK,
            "CHAT": CHAT,
        }
        logger.info("DB repositories loaded and attached to app.state")
    except ModuleNotFoundError as e:
        # Log full traceback and interpreter info to make environment mismatches
        # visible (e.g., packages installed in a different venv than the server).
        logger.exception(
            "DB import failed (ModuleNotFoundError). sys.executable=%s sys.version=%s; exception=%s",
            sys.executable,
            sys.version.replace("\n", " "),
            e,
        )
        logger.warning("DB features disabled. Ensure sqlalchemy and DB drivers are installed in the same Python interpreter used to run the server.")
    except Exception:
        logger.exception("Unexpected error while loading DB repositories")

from app.choose import choose_sample


class LoginRequest(BaseModel):
    username: str
    password: str


@app.post("/api/login")
async def login(body: LoginRequest):
    """Very small demo auth: accept any username/password but return a session token.

    In a real app you'd validate credentials against a DB or external provider.
    """
    logger = logging.getLogger("chatstub.auth")
    # Log the incoming login attempt (username only — do NOT log passwords)
    logger.info("login attempt username=%s", body.username)
    try:
        token = str(uuid.uuid4())
        # store minimal session info
        app.state.sessions[token] = {
            "username": body.username,
            "created": time.time(),
        }
        logger.info("login success username=%s", body.username)
        return {"token": token, "username": body.username}
    except Exception:
        logger.exception("login error for username=%s", body.username)
        raise


@app.get("/api/logout")
async def logout(authorization: Optional[str] = Header(None)):
    if not authorization:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED)
    token = authorization.split()[-1]
    app.state.sessions.pop(token, None)
    return {"ok": True}


@app.get("/api/me")
async def me(authorization: Optional[str] = Header(None)):
    if not authorization:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED)
    token = authorization.split()[-1]
    s = app.state.sessions.get(token)
    if not s:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED)
    return {"username": s["username"], "created": s["created"]}


@app.get("/api/auth/google")
async def auth_google():
    """Stub endpoint to begin Google OAuth flow. For the demo we just redirect
    to a fake consent page (in production you'd redirect to Google's OAuth URL).
    """
    # In a real flow you'd compute a redirect to Google with client_id/state/etc.
    return RedirectResponse(url="/google-consent.html")

@app.get("/api/health")
async def health():
    return {"ok": True}


class SessionCreate(BaseModel):
    title: str | None = None


class MessageCreate(BaseModel):
    role: str
    content: str
    content_format: str | None = "text"
    token_count: int | None = None
    metadata: dict | None = None


@app.get("/api/sessions")
async def api_list_sessions(request: Request, limit: int = 50, offset: int = 0):
    repos = getattr(request.app.state, "repos", None)
    if not repos or "CHAT" not in repos:
        return {"error": "CHAT repo not available"}
    sessions = repos["CHAT"].list_sessions(limit=limit, offset=offset)
    # Map session.meta_id -> a small object
    return {"sessions": sessions}


@app.post("/api/sessions")
async def api_create_session(request: Request, body: SessionCreate):
    repos = getattr(request.app.state, "repos", None)
    if not repos or "CHAT" not in repos:
        raise HTTPException(status_code=503, detail="CHAT repo not available")
    # ensure current DB login is known to v_users, otherwise triggers may fail
    try:
        ok = repos["CHAT"]._select("SELECT 1 FROM public.v_users WHERE user_user = current_user LIMIT 1", {})
        if not ok:
            raise HTTPException(status_code=500, detail="database user is not present in v_users; ensure the DB login maps to v_users.user_user = current_user")
    except HTTPException:
        raise
    except Exception:
        # if the check itself fails (missing view), surface helpful message
        raise HTTPException(status_code=500, detail="failed to verify v_users/current_user mapping; ensure DB views exist and are accessible")

    title = body.title or "Новый чат"
    meta_id = repos["CHAT"].create_session(title=title)
    return {"meta_id": meta_id, "title": title}


def _verify_db_current_user_or_400(request: Request):
    """Ensure current_user is present in public.v_users; raise HTTPException(500) with helpful text otherwise."""
    repos = getattr(request.app.state, "repos", None)
    if not repos or "CHAT" not in repos:
        raise HTTPException(status_code=503, detail="CHAT repo not available")
    try:
        ok = repos["CHAT"]._select("SELECT 1 FROM public.v_users WHERE user_user = current_user LIMIT 1", {})
        if not ok:
            raise HTTPException(status_code=500, detail="database user is not present in v_users; ensure the DB login maps to v_users.user_user = current_user")
    except HTTPException:
        raise
    except Exception:
        raise HTTPException(status_code=500, detail="failed to verify v_users/current_user mapping; ensure DB views exist and are accessible")


@app.put("/api/sessions/{session_meta}")
async def api_update_session(request: Request, session_meta: str, body: SessionCreate):
    """Update session metadata (currently only title)."""
    logger = logging.getLogger("chatstub.sessions")
    repos = getattr(request.app.state, "repos", None)
    if not repos or "CHAT" not in repos:
        logger.warning("update_session called but CHAT repo not available session=%s", session_meta)
        raise HTTPException(status_code=503, detail="CHAT repo not available")
    logger.info("update_session attempt session=%s title=%s", session_meta, body.title)
    try:
        updated = repos["CHAT"].update_session(session_meta, title=body.title)
        logger.info("update_session success session=%s updated=%s", session_meta, bool(updated))
        return {"updated": bool(updated)}
    except Exception as e:
        logger.exception("update_session error session=%s", session_meta)
        raise HTTPException(status_code=500, detail=str(e))


@app.delete("/api/sessions/{session_meta}")
async def api_delete_session(request: Request, session_meta: str):
    """Delete a session and its messages."""
    logger = logging.getLogger("chatstub.sessions")
    repos = getattr(request.app.state, "repos", None)
    if not repos or "CHAT" not in repos:
        logger.warning("delete_session called but CHAT repo not available session=%s", session_meta)
        raise HTTPException(status_code=503, detail="CHAT repo not available")
    logger.info("delete_session attempt session=%s", session_meta)
    try:
        deleted = repos["CHAT"].delete_session(session_meta)
        logger.info("delete_session success session=%s deleted=%s", session_meta, bool(deleted))
        return {"deleted": bool(deleted)}
    except Exception as e:
        logger.exception("delete_session error session=%s", session_meta)
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/api/sessions/{session_meta}/messages")
async def api_list_messages(request: Request, session_meta: str, after_seq: int | None = None, limit: int = 200, ascending: bool = True):
    repos = getattr(request.app.state, "repos", None)
    if not repos or "CHAT" not in repos:
        return {"error": "CHAT repo not available"}
    rows = repos["CHAT"].list_messages(session_meta=session_meta, after_seq=after_seq, limit=limit, ascending=ascending)
    return {"messages": rows}


@app.post("/api/sessions/{session_meta}/messages")
async def api_add_message(request: Request, session_meta: str, body: MessageCreate):
    logger = logging.getLogger("chatstub.messages")
    repos = getattr(request.app.state, "repos", None)
    if not repos or "CHAT" not in repos:
        logger.warning("add_message called but CHAT repo not available session=%s role=%s", session_meta, body.role)
        raise HTTPException(status_code=503, detail="CHAT repo not available")
    logger.info("add_message attempt session=%s role=%s content_len=%d", session_meta, body.role, len(body.content or ""))
    # verify DB login mapping prior to inserts so DB triggers relying on current_user don't fail unexpectedly
    _verify_db_current_user_or_400(request)
    try:
        meta_id, seq = repos["CHAT"].add_message(
            session_meta=session_meta,
            role=body.role,
            content=body.content,
            content_format=body.content_format or "text",
            token_count=body.token_count,
            metadata=body.metadata,
        )
        logger.info("add_message success session=%s role=%s meta_id=%s seq=%s", session_meta, body.role, meta_id, seq)
        return {"meta_id": meta_id, "seq": seq}
    except Exception as e:
        logger.exception("add_message error session=%s role=%s", session_meta, body.role)
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/api/chat")
async def chat(prompt: str = ""):
    return {"role": "assistant", "content": choose_sample(prompt)}


@app.get("/api/debug/agent-sub-kind")
async def debug_agent_sub_kind(request: Request, agent_name: str = "WishAgent", sub_kind_code: str = "check", in_out: str = "input"):
    """Debug endpoint: returns a single agent sub-kind as JSON.

    Example: /api/debug/agent-sub-kind?agent_name=WishAgent&sub_kind_code=check&in_out=input
    """
    logger = logging.getLogger("chatstub.debug")
    repos = getattr(request.app.state, "repos", None)
    if not repos or "AGENT_SK" not in repos:
        return {"error": "AGENT_SK repo not available"}
    try:
        one = repos["AGENT_SK"].get_one_by_code(agent_name, sub_kind_code, in_out=in_out, return_as="json")
        if one is None:
            return {"found": False}
        return {"found": True, "item": one, "result": one.get("result")}
    except Exception as e:
        logger.exception("Error fetching agent sub-kind")
        return {"error": str(e)}

@app.get("/api/chat/stream")
async def chat_stream(prompt: str = "", delay_ms: int = 25):
    text = choose_sample(prompt)
    chunks = []
    buf = ""
    for ch in text:
        buf += ch
        if ch.isspace():
            chunks.append(buf)
            buf = ""
    if buf:
        chunks.append(buf)

    async def gen():
        yield "retry: 1500\n\n"
        for w in chunks:
            await asyncio.sleep(max(0, delay_ms)/1000.0)
            for line in w.splitlines(True):
                yield f"data: {line}\n"
            yield "\n"
        yield "event: done\ndata: [DONE]\n\n"

    return StreamingResponse(gen(), media_type="text/event-stream")


@app.post('/api/uploads')
async def upload_file(request: Request):
    """Accept a raw file upload in the request body. The client should set
    an X-Filename header or ?filename=... query param. This avoids requiring
    python-multipart for simple local development.
    """
    logger = logging.getLogger('chatstub.uploads')
    try:
        uploads_dir = os.path.join(os.getcwd(), 'static', 'uploads')
        os.makedirs(uploads_dir, exist_ok=True)
        fname = request.headers.get('x-filename') or request.query_params.get('filename')
        if not fname:
            fname = f'file-{uuid.uuid4().hex}'
        filename = os.path.basename(fname)
        dest_path = os.path.join(uploads_dir, filename)
        if os.path.exists(dest_path):
            name, ext = os.path.splitext(filename)
            filename = f"{name}-{uuid.uuid4().hex[:6]}{ext}"
            dest_path = os.path.join(uploads_dir, filename)
        body = await request.body()
        with open(dest_path, 'wb') as f:
            f.write(body)
        url = f"/uploads/{filename}"
        logger.info('uploaded file saved %s size=%s', filename, os.path.getsize(dest_path))
        return JSONResponse({'url': url, 'name': filename, 'size': os.path.getsize(dest_path)})
    except Exception:
        logger.exception('upload error')
        raise HTTPException(status_code=500, detail='upload failed')


# New attachment API (multipart) -------------------------------------------------
router = APIRouter()


@router.post("/api/messages/{message_meta}/attachments", summary="Upload attachment for a message")
async def upload_message_attachment(request: Request, message_meta: str, file: UploadFile = File(...)):
    logger = logging.getLogger('chatstub.attachments')
    repos = getattr(request.app.state, 'repos', None)
    if not repos or 'CHAT' not in repos:
        logger.warning('attachment upload called but CHAT repo not available')
        raise HTTPException(status_code=503, detail='CHAT repo not available')
    # verify DB login mapping prior to inserts so DB triggers relying on current_user don't fail unexpectedly
    _verify_db_current_user_or_400(request)
    try:
        data = await file.read()
        sha = hashlib.sha256(data).hexdigest()
        size = len(data)
        repo = repos['CHAT']
        blob_meta = repo.upsert_blob(content=data, sha256=sha, size_bytes=size)
        att_meta = repo.attach_blob_to_message(
            message_meta=message_meta,
            filename=file.filename or 'file',
            mime_type=file.content_type or 'application/octet-stream',
            size_bytes=size,
            blob_meta_id=blob_meta,
        )
        return {"attachment_meta": att_meta, "blob_meta": blob_meta, "sha256": sha, "size": size}
    except Exception:
        logger.exception('attachment upload failed')
        raise HTTPException(status_code=500, detail='upload failed')


@router.get("/api/attachments/{attachment_meta}", summary="Download attachment")
def download_attachment(request: Request, attachment_meta: str):
    repos = getattr(request.app.state, 'repos', None)
    if not repos or 'CHAT' not in repos:
        raise HTTPException(status_code=503, detail='CHAT repo not available')
    # First try the canonical view (v_message_attachments). If the view isn't
    # present or returns nothing, fall back to the physical table
    # t_message_attachments (created by migration) so downloads still work.
    row = repos['CHAT']._select(
        "SELECT a.filename, a.mime_type, b.blob_content "
        "FROM public.v_message_attachments a "
        "JOIN public.t_blobs b ON b.meta_id=a.blob_meta_id "
        "WHERE a.meta_id=:mid LIMIT 1",
        {"mid": attachment_meta},
    )
    if not row:
        # fallback to physical table
        row = repos['CHAT']._select(
            "SELECT m.filename, m.mime_type, b.blob_content "
            "FROM public.t_message_attachments m "
            "JOIN public.t_blobs b ON b.meta_id = m.blob_meta_id "
            "WHERE m.meta_id = :mid LIMIT 1",
            {"mid": attachment_meta},
        )
    if not row:
        raise HTTPException(status_code=404, detail='not found')
    r = row[0]
    content = bytes(r['blob_content']) if r['blob_content'] is not None else b''
    return StreamingResponse(iter([content]), media_type=r.get('mime_type') or 'application/octet-stream', headers={"Content-Disposition": f'attachment; filename="{r.get("filename")}"'})

# Mount router routes after API definitions so static mount remains at root
app.include_router(router)


# Serve the frontend static files at the application root. Mount this after
# the API routes so it doesn't shadow API endpoints. Use an absolute path so
# static files are found even when the process working directory differs.
BASE_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
STATIC_DIR = os.path.join(BASE_DIR, 'static')
app.mount("/", StaticFiles(directory=STATIC_DIR, html=True), name="static")

