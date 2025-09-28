#!/usr/bin/env python3
from app.db.config import get_settings
from app.db.engine import create_engine_from_settings
from sqlalchemy import text
import json

def run():
    try:
        cfg = get_settings()
        engine = create_engine_from_settings(cfg)
    except Exception as e:
        print('CONFIG/ENGINE ERROR:', e)
        raise

    queries = [
        ("current_user", "SELECT current_user as cu;"),
        ("v_users_current", "SELECT * FROM public.v_users WHERE user_user = current_user;"),
        ("v_chat_messages_cols", "SELECT column_name, data_type FROM information_schema.columns WHERE table_schema='public' AND table_name='v_chat_messages' ORDER BY ordinal_position;"),
        ("v_chat_messages_viewdef", "SELECT pg_get_viewdef('public.v_chat_messages', true) as viewdef;"),
        ("tg_function_src", "SELECT oid, proname, pg_get_functiondef(oid) as src FROM pg_proc WHERE proname='tg_v_chat_messages_upsert';"),
        ("triggers_on_v_chat_messages", "SELECT t.tgname, pg_get_triggerdef(t.oid) as def FROM pg_trigger t JOIN pg_class c ON t.tgrelid = c.oid WHERE c.relname = 'v_chat_messages';"),
    ]

    with engine.connect() as conn:
        for name, sql in queries:
            print('\n====', name, '====')
            try:
                res = conn.execute(text(sql)).mappings().all()
                print(json.dumps(res, default=str, ensure_ascii=False, indent=2))
            except Exception as e:
                print('ERROR running query:', sql)
                print(e)

if __name__ == '__main__':
    run()
