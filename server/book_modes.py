"""Book-scoped creation modes and recoverable directory management."""
from contextlib import closing
from typing import Literal
from fastapi import APIRouter, HTTPException, Request
from pydantic import BaseModel, Field
from server import book_store as books, chat_sessions

router = APIRouter(prefix='/api/books/{bid}/directory')
SCHEMA = '''
CREATE TABLE IF NOT EXISTS book_modes(book_id TEXT PRIMARY KEY REFERENCES books(id) ON DELETE CASCADE,
 mode TEXT NOT NULL CHECK(mode IN ('directory','companion')));
CREATE TABLE IF NOT EXISTS book_directory_state(book_id TEXT PRIMARY KEY REFERENCES books(id) ON DELETE CASCADE,
 revision INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS book_topic_archives(topic_id TEXT PRIMARY KEY REFERENCES book_topics(id) ON DELETE CASCADE,
 archived TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP);
CREATE TABLE IF NOT EXISTS companion_returns(book_id TEXT NOT NULL REFERENCES books(id) ON DELETE CASCADE,
 request_id TEXT NOT NULL, left_at INTEGER NOT NULL, delivered_at INTEGER NOT NULL, message_id TEXT,
 PRIMARY KEY(book_id,request_id));
'''


def ensure_schema(c):
    expected = {'book_modes', 'book_directory_state', 'book_topic_archives', 'companion_returns'}
    found = {row[0] for row in c.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    if not expected.issubset(found):
        c.executescript(SCHEMA)
        c.commit()


def mode(c, bid):
    if not c.execute("SELECT 1 FROM sqlite_master WHERE name='book_modes'").fetchone():
        return 'companion'
    row = c.execute('SELECT mode FROM book_modes WHERE book_id=?', (bid,)).fetchone()
    return row['mode'] if row else 'companion'  # Existing books keep the previous interview entry.


def archived(c, tid):
    return (c.execute("SELECT 1 FROM sqlite_master WHERE name='book_topic_archives'").fetchone()
            and c.execute('SELECT 1 FROM book_topic_archives WHERE topic_id=?', (tid,)).fetchone())


def directory(c, bid):
    books.active(c, bid)
    if mode(c, bid) != 'directory':
        raise HTTPException(409, '这本书采用陪伴模式，不提供访谈目录')
    state = c.execute('SELECT revision FROM book_directory_state WHERE book_id=?', (bid,)).fetchone()
    rows = [dict(row) for row in c.execute('''SELECT t.id,t.title,t.question,t.number,t.revision,
        a.archived AS deleted_at FROM book_topics t LEFT JOIN book_topic_archives a ON a.topic_id=t.id
        WHERE t.book_id=? ORDER BY t.number''', (bid,))]
    return {'revision': state['revision'] if state else 0,
            'topics': [r for r in rows if r['deleted_at'] is None],
            'archived': [r for r in rows if r['deleted_at'] is not None]}


def begin(c, bid, revision):
    value = directory(c, bid)
    if value['revision'] != revision:
        raise HTTPException(409, '目录已在其他位置更新，请刷新后再操作')
    return value


def renumber(c, bid, ids=None):
    current = directory(c, bid)
    ids = ids if ids is not None else [r['id'] for r in current['topics']] + [r['id'] for r in current['archived']]
    offset = c.execute('SELECT COALESCE(MAX(number),0)+1 FROM book_topics WHERE book_id=?', (bid,)).fetchone()[0]
    c.execute('UPDATE book_topics SET number=number+? WHERE book_id=?', (offset, bid))
    c.executemany('UPDATE book_topics SET number=? WHERE id=?', ((n, tid) for n, tid in enumerate(ids, 1)))
    c.execute('''UPDATE chapters SET position=(SELECT number FROM book_topics WHERE chapter_id=chapters.id)
        WHERE id IN (SELECT chapter_id FROM book_topics WHERE book_id=?)''', (bid,))


def advance(c, bid):
    c.execute('''INSERT INTO book_directory_state VALUES(?,1) ON CONFLICT(book_id)
        DO UPDATE SET revision=revision+1''', (bid,))
    c.execute('UPDATE books SET updated=CURRENT_TIMESTAMP WHERE id=?', (bid,))
    return directory(c, bid)


class Revision(BaseModel):
    revision: int = Field(ge=0)


class Item(Revision):
    title: str = Field(min_length=1, max_length=100)
    question: str = Field(min_length=1, max_length=1000)
    def clean(self):
        if not self.title.strip() or not self.question.strip():
            raise HTTPException(400, '请填写目录名称和预设问题')
        return self.title.strip(), self.question.strip()


class NewItem(Item):
    id: str = Field(pattern=r'^[0-9a-f]{32}$')


class Order(Revision):
    ids: list[str] = Field(max_length=500)


def initialize(c):
    from server import book_api
    book_api.initialize(c)


@router.get('')
def read_directory(bid: str, request: Request):
    backend.require(request)
    with closing(backend.db()) as c:
        initialize(c)
        return directory(c, bid)


@router.post('/items')
def add_item(bid: str, data: NewItem, request: Request):
    backend.require(request)
    title, question = data.clean()
    with closing(backend.db()) as c:
        initialize(c)
        with c:
            c.execute('BEGIN IMMEDIATE')
            current = directory(c, bid)
            old = c.execute('SELECT book_id,title,question FROM book_topics WHERE id=?', (data.id,)).fetchone()
            if old:
                if tuple(old) != (bid, title, question):
                    raise HTTPException(409, '这个新增请求已用于其他目录')
                return current
            begin(c, bid, data.revision)
            number = c.execute('SELECT COALESCE(MAX(number),0)+1 FROM book_topics WHERE book_id=?', (bid,)).fetchone()[0]
            if len(current['topics']) >= 500:
                raise HTTPException(400, '目录数量已达上限')
            books.add_topic(c, bid, number, '自定义章节', title, question, data.id)
            renumber(c, bid)
            return advance(c, bid)


@router.patch('/items/{tid}')
def edit_item(bid: str, tid: str, data: Item, request: Request):
    backend.require(request)
    title, question = data.clean()
    with closing(backend.db()) as c:
        initialize(c)
        with c:
            c.execute('BEGIN IMMEDIATE')
            begin(c, bid, data.revision)
            topic = books.topic(c, bid, tid)
            c.execute('UPDATE book_topics SET title=?,question=?,revision=revision+1 WHERE id=?', (title, question, tid))
            c.execute('UPDATE chat_sessions SET title=? WHERE id=?', (title, tid))
            if topic['chapter_id']:
                c.execute('UPDATE chapters SET title=? WHERE id=?', (title, topic['chapter_id']))
            return advance(c, bid)


@router.put('/order')
def order_items(bid: str, data: Order, request: Request):
    backend.require(request)
    with closing(backend.db()) as c:
        initialize(c)
        with c:
            c.execute('BEGIN IMMEDIATE')
            current = begin(c, bid, data.revision)
            if len(data.ids) != len(set(data.ids)) or set(data.ids) != {r['id'] for r in current['topics']}:
                raise HTTPException(409, '排序必须包含当前全部目录，且不能重复')
            ids = data.ids + [r['id'] for r in current['archived']]
            renumber(c, bid, ids)
            return advance(c, bid)


@router.post('/items/{tid}/{action}')
def archive_item(bid: str, tid: str, action: Literal['archive', 'restore'], data: Revision, request: Request):
    backend.require(request)
    with closing(backend.db()) as c:
        initialize(c)
        with c:
            c.execute('BEGIN IMMEDIATE')
            current = begin(c, bid, data.revision)
            row = c.execute('SELECT id FROM book_topics WHERE book_id=? AND id=?', (bid, tid)).fetchone()
            if row is None:
                raise HTTPException(404, '找不到本书的这个目录')
            if action == 'archive':
                c.execute('INSERT OR IGNORE INTO book_topic_archives(topic_id) VALUES(?)', (tid,))
                if chat_sessions.active(c, bid) == tid:
                    other = next((r['id'] for r in current['topics'] if r['id'] != tid), None)
                    if other:
                        chat_sessions.select(c, bid, other)
                    else:
                        c.execute('DELETE FROM active_chat_session WHERE person_id=?', (bid,))
            else:
                c.execute('DELETE FROM book_topic_archives WHERE topic_id=?', (tid,))
            renumber(c, bid)
            return advance(c, bid)


from server import app as backend
