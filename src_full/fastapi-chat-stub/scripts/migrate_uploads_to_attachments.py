#!/usr/bin/env python3
"""Migrate files from static/uploads into DB blobs and attach them to messages.

Usage:
  scripts/migrate_uploads_to_attachments.py [--message MESSAGE_META] [--session SESSION_META] [--dry-run]

If --message is provided, attachments are attached to that message. If --session
is provided and --message is absent, the script will create a new message in that
session for each file. If neither provided, the script will create a session
called 'migrated-uploads' and attach each file as a new message in that session.

Dry-run prints actions without performing DB changes.
"""
import argparse
import os
import hashlib
from pathlib import Path
from app.db.db import CHAT

UPLOADS_DIR = Path(__file__).resolve().parents[1] / 'static' / 'uploads'

parser = argparse.ArgumentParser()
parser.add_argument('--message', help='Attach all files to this message_meta')
parser.add_argument('--session', help='Attach into this session_meta (creates messages)')
parser.add_argument('--dry-run', action='store_true')
args = parser.parse_args()

files = sorted([p for p in UPLOADS_DIR.iterdir() if p.is_file()])
if not files:
    print('No files found in', UPLOADS_DIR)
    exit(0)

print('Found', len(files), 'files in', UPLOADS_DIR)

session_meta = args.session
message_meta = args.message

def sha256_of(path: Path) -> str:
    h = hashlib.sha256()
    with path.open('rb') as f:
        while True:
            b = f.read(8192)
            if not b: break
            h.update(b)
    return h.hexdigest()

for p in files:
    name = p.name
    size = p.stat().st_size
    sha = sha256_of(p)
    print('\nFile:', name, 'size=', size, 'sha256=', sha)
    if args.dry_run:
        print('  DRY RUN: would call upsert_blob and attach_blob_to_message')
        continue
    # upsert blob
    with open(p, 'rb') as fh:
        data = fh.read()
    try:
        blob_meta = CHAT.upsert_blob(content=data, sha256=sha, size_bytes=size)
        print('  upsert_blob ->', blob_meta)
    except Exception as e:
        print('  upsert_blob failed:', e)
        continue
    # attach to message
    if message_meta:
        try:
            att_meta = CHAT.attach_blob_to_message(message_meta=message_meta, filename=name, mime_type='application/octet-stream', size_bytes=size, blob_meta_id=blob_meta)
            print('  attached ->', att_meta)
        except Exception as e:
            print('  attach failed:', e)
    else:
        # create a message in session (or create session if needed)
        try:
            if not session_meta:
                # create a record meta explicitly and insert a t_chat_sessions row
                try:
                    # create tb_record_meta and t_chat_sessions in one transaction so the record is visible to triggers
                    from sqlalchemy import text
                    with CHAT.engine.begin() as conn:
                        new_meta = conn.execute(text("INSERT INTO public.tb_record_meta DEFAULT VALUES RETURNING id;"), {}).fetchone()[0]
                        # determine a user_id to own the session (try current_user mapping in v_users)
                        try:
                            urow = conn.execute(text("SELECT user_id FROM public.v_users WHERE user_user = current_user LIMIT 1"), {}).fetchone()
                            user_id = urow[0] if urow else 0
                        except Exception:
                            user_id = 0
                        conn.execute(
                            text("INSERT INTO public.t_chat_sessions (meta_id, user_id, title, group_meta) VALUES (:meta, :user_id, :title, :group);"),
                            {"meta": new_meta, "user_id": user_id, "title": 'migrated-uploads', "group": None},
                        )
                    session_meta = new_meta
                    print('  created session ->', session_meta)
                except Exception as e:
                    print('  create session failed:', e)
                    raise
            meta_id, seq = CHAT.add_message(session_meta=session_meta, role='user', content=f'Attached file: {name}', content_format='text', token_count=0)
            print('  created message ->', meta_id, 'seq=', seq)
            # prefer the v_message_attachments view if it exists; otherwise store attachment info in t_chat_messages.metadata
            try:
                has_view = CHAT._select("SELECT 1 FROM pg_views WHERE viewname='v_message_attachments'", [])
            except Exception:
                has_view = []
            if has_view:
                att_meta = CHAT.attach_blob_to_message(message_meta=meta_id, filename=name, mime_type='application/octet-stream', size_bytes=size, blob_meta_id=blob_meta)
                print('  attached ->', att_meta)
            else:
                # fallback: add attachments array to t_chat_messages.metadata
                try:
                    from sqlalchemy import text
                    import json
                    att = {
                        'filename': name,
                        'mime_type': 'application/octet-stream',
                        'size_bytes': size,
                        'blob_meta_id': str(blob_meta),
                    }
                    att_json = json.dumps([att])
                    with CHAT.engine.begin() as conn:
                        conn.execute(
                            text(
                                "UPDATE public.t_chat_messages SET metadata = COALESCE(metadata, '{}'::jsonb) || jsonb_build_object('attachments', COALESCE(metadata->'attachments', '[]'::jsonb) || (:att)::jsonb) WHERE meta_id = :mid"
                            ),
                            {"att": att_json, "mid": meta_id},
                        )
                    print('  attached metadata -> stored in t_chat_messages.metadata')
                except Exception as e:
                    print('  attach metadata failed:', e)
        except Exception as e:
            print('  create/attach failed:', e)

print('\nDone')
