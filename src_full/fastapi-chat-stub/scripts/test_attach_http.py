#!/usr/bin/env python3
"""Test script: create session, add message, upload test file, download attachment.
Run with the project's venv Python: .venv/bin/python scripts/test_attach_http.py
"""
import sys
import os
import requests
from pprint import pprint

BASE = os.environ.get('BASE_URL', 'http://127.0.0.1:8241')
TEST_FILE = os.path.join(os.path.dirname(__file__), '..', 'static', 'uploads', 'test-upload.txt')

def hexdump(b, n=128):
    out = []
    for i in range(0, min(len(b), n), 16):
        chunk = b[i:i+16]
        hexs = ' '.join(f"{c:02x}" for c in chunk)
        ascii_ = ''.join((chr(c) if 32 <= c < 127 else '.') for c in chunk)
        out.append(f"{i:08x}  {hexs:<48}  |{ascii_}|")
    return '\n'.join(out)

s = requests.Session()
print('health ->', s.get(f"{BASE}/api/health").status_code)

print('\nCreate session...')
r = s.post(f"{BASE}/api/sessions", json={"title": "test-session"})
print('status', r.status_code)
try:
    j = r.json()
except Exception:
    print('body:', r.text)
    sys.exit(1)
print('resp:', j)
session_meta = j.get('meta_id')
if not session_meta:
    print('no session_meta, abort')
    sys.exit(1)

print('\nAdd message...')
msg_body = {"role": "user", "content": "hello world", "content_format": "text", "token_count": 1}
r = s.post(f"{BASE}/api/sessions/{session_meta}/messages", json=msg_body)
print('status', r.status_code)
try:
    jm = r.json()
except Exception:
    print('body:', r.text)
    sys.exit(1)
print('resp:', jm)
message_meta = jm.get('meta_id')
if not message_meta:
    print('no message_meta, abort')
    sys.exit(1)

print('\nUpload attachment...')
with open(TEST_FILE, 'rb') as fh:
    files = {'file': (os.path.basename(TEST_FILE), fh, 'text/plain')}
    r = s.post(f"{BASE}/api/messages/{message_meta}/attachments", files=files)
print('status', r.status_code)
try:
    ju = r.json()
except Exception:
    print('body:', r.text)
    sys.exit(1)
print('resp:')
pprint(ju)
attachment_meta = ju.get('attachment_meta')
if not attachment_meta:
    print('no attachment_meta, abort')
    sys.exit(1)

print('\nDownload attachment...')
r = s.get(f"{BASE}/api/attachments/{attachment_meta}", stream=True)
print('status', r.status_code)
print('headers:')
for k,v in r.headers.items():
    print(f"{k}: {v}")
content = r.raw.read(1024)
print('\nbody sample:')
print(hexdump(content, 256))
print('\nDone')
