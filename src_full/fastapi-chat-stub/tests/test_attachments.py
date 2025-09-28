import hashlib
import pytest

try:
    from app.db.db import CHAT
except Exception:
    CHAT = None


pytestmark = pytest.mark.skipif(not CHAT, reason="DB not configured")


def test_blob_attach_list_delete():
    repo = CHAT
    data = b'hello-world-test'
    sha = hashlib.sha256(data).hexdigest()
    size = len(data)

    # upsert blob
    blob_meta = repo.upsert_blob(content=data, sha256=sha, size_bytes=size)
    assert blob_meta is not None

    # create a session and message to attach to
    sess = repo.create_session(title='test attach')
    mid, seq = repo.add_message(session_meta=sess, role='user', content='attach test')
    assert mid is not None

    # attach blob to message
    att_meta = repo.attach_blob_to_message(message_meta=mid, filename='x.txt', mime_type='text/plain', size_bytes=size, blob_meta_id=blob_meta)
    assert att_meta is not None

    # list attachments
    atts = repo.list_attachments(message_meta=mid)
    assert any(a['meta_id'] == att_meta for a in atts)

    # delete
    r = repo.delete_attachment(attachment_meta=att_meta)
    assert r >= 0