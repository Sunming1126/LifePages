"""A single in-app welcome after an hour away; no push or model call."""
import asyncio
import time
import uuid
from contextlib import closing
from fastapi import APIRouter, HTTPException, Request
from pydantic import BaseModel, Field
from server import app as backend, book_api, book_modes, book_store as books, chat_sessions, interview

router = APIRouter(prefix='/api/books/{bid}/interview')


class ReturnInput(BaseModel):
    request_id: str = Field(pattern=r'^[0-9a-f]{32}$')
    left_at: int = Field(ge=0)
    last_user_id: str | None = Field(default=None, max_length=128)


@router.post('/resume')
async def resume(bid: str, data: ReturnInput, request: Request):
    backend.require(request)
    lock = backend._turn_locks.setdefault(f'{backend.ACCOUNT.get()}:{bid}', asyncio.Lock())
    async with lock:
        with closing(backend.db()) as c:
            book_api.initialize(c)
            with c:
                c.execute('BEGIN IMMEDIATE')
                books.active(c, bid)
                if book_modes.mode(c, bid) != 'companion':
                    raise HTTPException(409, '目录模式不发送陪伴续聊消息')
                state = interview.find(c, bid)
                if state is None:
                    raise HTTPException(409, '请先打开这本书的聊天')
                previous = c.execute('SELECT left_at,message_id FROM companion_returns WHERE book_id=? AND request_id=?',
                                     (bid, data.request_id)).fetchone()
                if previous and previous['left_at'] != data.left_at:
                    raise HTTPException(409, '这个续聊请求已用于其他返回记录')
                mid = previous['message_id'] if previous else None
                if previous is None:
                    now = int(time.time())
                    last = c.execute('''SELECT m.id,CAST(strftime('%s',m.created) AS INTEGER) AS stamp
                        FROM messages m JOIN chat_session_messages sm ON sm.message_id=m.id
                        WHERE m.person_id=? AND sm.session_id=? AND m.role='user' ORDER BY m.rowid DESC LIMIT 1''',
                        (bid, state['session_id'])).fetchone()
                    recent = c.execute('''SELECT MAX(delivered_at) FROM companion_returns
                        WHERE book_id=? AND message_id IS NOT NULL''', (bid,)).fetchone()[0]
                    pending = c.execute('SELECT 1 FROM chat_turns WHERE person_id=? AND assistant_id IS NULL LIMIT 1', (bid,)).fetchone()
                    allowed = (last is not None and last['id'] == data.last_user_id and last['stamp'] <= data.left_at
                               and now - data.left_at >= 3600 and not pending
                               and (recent is None or now - recent >= 3600))
                    if allowed:
                        mid = uuid.uuid4().hex
                        c.execute('INSERT INTO messages(id,person_id,role,text) VALUES(?,?,?,?)',
                                  (mid, bid, 'assistant', '又见面啦。您想接着上次的聊天说，还是换个新话题？'))
                        chat_sessions.bind(c, bid, state['session_id'], mid)
                        c.execute('UPDATE books SET updated=CURRENT_TIMESTAMP WHERE id=?', (bid,))
                    c.execute('INSERT INTO companion_returns VALUES(?,?,?,?,?)',
                              (bid, data.request_id, data.left_at, now, mid))
                return {'message_id': mid, 'messages': interview.history(c, bid),
                        'interview': interview.public_state(c, state)}
