"""Books reuse the narrator ID and topic IDs reuse the session ID."""
import json
import os
import re
import uuid

from fastapi import HTTPException

from server import chat_sessions, interview, memory
from server.book_topics import TEMPLATES

SCHEMA = """
CREATE TABLE IF NOT EXISTS books (
    id TEXT PRIMARY KEY REFERENCES people(id), title TEXT NOT NULL, author TEXT NOT NULL,
    deleted_at INTEGER, updated TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS book_topics (
    id TEXT PRIMARY KEY REFERENCES chat_sessions(id), book_id TEXT NOT NULL REFERENCES books(id),
    number INTEGER NOT NULL, theme TEXT NOT NULL, title TEXT NOT NULL, question TEXT NOT NULL,
    opened INTEGER NOT NULL DEFAULT 0, chapter_id TEXT REFERENCES chapters(id),
    checked_rowid INTEGER NOT NULL DEFAULT 0, revision INTEGER NOT NULL DEFAULT 0,
    UNIQUE(book_id,number)
);
CREATE TABLE IF NOT EXISTS book_state (
    singleton INTEGER PRIMARY KEY CHECK(singleton=1), active_id TEXT REFERENCES books(id)
);
CREATE TABLE IF NOT EXISTS topic_drafts (
    topic_id TEXT PRIMARY KEY REFERENCES book_topics(id), id TEXT NOT NULL UNIQUE,
    body TEXT NOT NULL, sources TEXT NOT NULL, through_rowid INTEGER NOT NULL, base_revision INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS retired_books (id TEXT PRIMARY KEY);
CREATE TABLE IF NOT EXISTS book_cleanup (
    kind TEXT NOT NULL, owner TEXT NOT NULL, value TEXT NOT NULL, PRIMARY KEY(kind,owner,value)
);
"""
EDITOR_SCHEMA = """
CREATE TABLE IF NOT EXISTS book_templates (
    book_id TEXT PRIMARY KEY REFERENCES books(id) ON DELETE CASCADE, template_id TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS topic_insertions (
    topic_id TEXT PRIMARY KEY REFERENCES book_topics(id) ON DELETE CASCADE,
    after_id TEXT NOT NULL, title TEXT NOT NULL, question TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS topic_manuscripts (
    topic_id TEXT PRIMARY KEY REFERENCES book_topics(id) ON DELETE CASCADE,
    blocks TEXT NOT NULL, image_count INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS topic_images (
    id TEXT PRIMARY KEY, topic_id TEXT NOT NULL REFERENCES book_topics(id) ON DELETE CASCADE,
    data BLOB NOT NULL
);
"""
TRASH_SECONDS = 30 * 86400


def ensure_editor(c):
    for statement in EDITOR_SCHEMA.split(';'):
        if statement.strip():
            c.execute(statement)


def managed(c):
    return bool(c.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='book_state'").fetchone()
                and c.execute('SELECT 1 FROM book_state').fetchone())


def active(c, bid):
    if managed(c) and not c.execute('SELECT 1 FROM books WHERE id=? AND deleted_at IS NULL', (bid,)).fetchone():
        raise HTTPException(404, '找不到可用的书籍')


def topic(c, bid, tid):
    if not managed(c):
        raise HTTPException(404, '书架尚未初始化')
    active(c, bid)
    row = c.execute('SELECT * FROM book_topics WHERE id=? AND book_id=?', (tid, bid)).fetchone()
    if row is None:
        raise HTTPException(404, '找不到本书的这个章节')
    from server import book_modes
    if book_modes.archived(c, tid):
        raise HTTPException(410, '这个目录已移入最近删除，可在管理目录中恢复')
    return row


def get_blocks(c, topic):
    row = c.execute('SELECT blocks FROM topic_manuscripts WHERE topic_id=?',
                    (topic['id'],)).fetchone()
    if row:
        return json.loads(row[0])
    if topic['chapter_id']:
        body = c.execute('SELECT content FROM chapters WHERE id=?', (topic['chapter_id'],)).fetchone()[0]
        if body.strip():
            return [{'id': topic['id'], 'kind': 'text', 'text': body}]
    return []


def manuscript_snapshot(c, topic):
    tid = topic['id']
    proposal = c.execute('SELECT id FROM topic_drafts WHERE topic_id=?', (tid,)).fetchone()
    new_material = c.execute('''SELECT 1 FROM chat_session_messages sm JOIN messages m
        ON m.id=sm.message_id WHERE sm.session_id=? AND m.role='user' AND m.rowid>? LIMIT 1''',
        (tid, topic['checked_rowid'])).fetchone()
    return {
        **{key: topic[key] for key in ('id', 'number', 'title', 'theme', 'question', 'revision')},
        'blocks': get_blocks(c, topic), 'draft_id': proposal[0] if proposal else None,
        'has_narrations': bool(new_material),
    }



def add_topic(c, bid, number, theme, title, question, tid=None, cid=None):
    tid = tid or uuid.uuid4().hex
    c.execute('INSERT INTO chat_sessions(id,person_id,title) VALUES(?,?,?)', (tid, bid, title))
    c.execute('''INSERT INTO book_topics(id,book_id,number,theme,title,question,chapter_id)
        VALUES(?,?,?,?,?,?,?)''', (tid, bid, number, theme, title, question, cid))
    return tid


def seed(c, bid, title, author, template='life', *, seed_topics=True):
    c.execute('INSERT INTO books(id,title,author) VALUES(?,?,?)', (bid, title, author))
    c.execute('INSERT INTO book_templates VALUES(?,?)', (bid, template))
    if seed_topics:
        for number, (theme, name, question) in enumerate(TEMPLATES[template][1], 1):
            add_topic(c, bid, number, theme, name, question)


def create(c, title, name, author, bid=None, template='life', *, seed_topics=True):
    bid = bid or uuid.uuid4().hex
    c.execute('INSERT INTO people(id,name) VALUES(?,?)', (bid, name))
    seed(c, bid, title, author, template, seed_topics=seed_topics)
    c.execute('UPDATE book_state SET active_id=? WHERE singleton=1', (bid,))
    return bid


def attach_legacy_chapters(c, bid):
    query = '''SELECT ch.id,ch.title FROM chapters ch WHERE ch.person_id=?
        AND TRIM(ch.content)!='' AND NOT EXISTS(
            SELECT 1 FROM book_topics t WHERE t.chapter_id=ch.id)
        ORDER BY ch.position,ch.rowid'''
    if not c.execute(query + ' LIMIT 1', (bid,)).fetchone():
        return
    with c:
        c.execute('BEGIN IMMEDIATE')
        active(c, bid)
        rows = c.execute(query, (bid,)).fetchall()
        last = c.execute('SELECT MAX(number) FROM book_topics WHERE book_id=?', (bid,)).fetchone()[0] or 0
        for number, row in enumerate(rows, last + 1):
            add_topic(c, bid, number, '已有书稿', row['title'],
                      '您还记得和这一章有关的哪些事情？', cid=row['id'])


def queue_audio(c, query, args=()):
    rows = c.execute(query, args)
    c.executemany("INSERT OR IGNORE INTO book_cleanup VALUES('audio','',?)",
                  ((row[0],) for row in rows if row[0] and re.fullmatch(r'[0-9a-f]{32}\.wav', row[0])))


def queue_vectors(c, where='', args=()):
    c.execute(f"INSERT OR IGNORE INTO book_cleanup SELECT 'vector',person_id,id FROM memory_items {where}", args)


def migrate(c):
    """Atomic and idempotent. Audio-only rows keep existing QR links resolvable."""
    c.executescript(SCHEMA + EDITOR_SCHEMA + memory.SCHEMA)
    c.execute('PRAGMA secure_delete=ON')
    c.execute('BEGIN IMMEDIATE')
    if managed(c):
        return
    narrators = c.execute('''SELECT p.* FROM people p ORDER BY
        COALESCE((SELECT MAX(m.rowid) FROM messages m WHERE m.person_id=p.id),0) DESC,p.rowid DESC''').fetchall()
    if os.getenv('LIFEPAGES_ALLOW_BOOK_MIGRATION') != '1' and (
        c.execute('SELECT 1 FROM messages LIMIT 1').fetchone()
        or c.execute('SELECT 1 FROM chapters LIMIT 1').fetchone()
    ):
        raise HTTPException(503, '请先备份旧数据并启用书架迁移')
    c.execute('INSERT INTO book_state(singleton) VALUES(1)')
    if not narrators:
        create(c, '我的回忆录', '您', '我')
        return
    memory.advance(c, memory.settings(c)[0])
    queue_vectors(c)
    queue_audio(c, '''SELECT audio FROM messages WHERE id NOT IN (
        SELECT a.message_id FROM chapter_audio a JOIN chapters ch ON ch.id=a.chapter_id
        WHERE TRIM(ch.content)!='')''')
    c.execute("INSERT OR IGNORE INTO book_cleanup SELECT 'share','',token_hash FROM shares WHERE chapter_id IN (SELECT id FROM chapters WHERE TRIM(content)='')")
    c.execute('DELETE FROM memory_edges')
    c.execute('DELETE FROM memory_nodes')
    c.execute('DELETE FROM memory_items')
    c.execute('DELETE FROM memory_progress')
    c.execute('DELETE FROM chat_turns')
    c.execute('DELETE FROM active_chat_session')
    c.execute('DELETE FROM chat_session_messages')
    c.execute('DELETE FROM chat_sessions')
    c.execute('DELETE FROM chapter_sources')
    c.execute("DELETE FROM shares WHERE chapter_id IN (SELECT id FROM chapters WHERE TRIM(content)='')")
    c.execute("DELETE FROM chapter_audio WHERE chapter_id IN (SELECT id FROM chapters WHERE TRIM(content)='')")
    c.execute("DELETE FROM chapters WHERE TRIM(content)=''")
    c.execute('DELETE FROM messages WHERE id NOT IN (SELECT message_id FROM chapter_audio)')
    c.execute("UPDATE messages SET role='archived_audio',text=''")
    for row in narrators:
        seed(c, row['id'], f"{row['name']}的回忆录", row['name'])
    c.execute('UPDATE book_state SET active_id=? WHERE singleton=1', (narrators[0]['id'],))


def open_topic(c, bid, tid):
    row = topic(c, bid, tid)
    if not row['opened']:
        mid = uuid.uuid4().hex
        c.execute("INSERT INTO messages(id,person_id,role,text) VALUES(?,?,'assistant',?)",
                  (mid, bid, row['question']))
        chat_sessions.bind(c, bid, tid, mid)
        c.execute('UPDATE book_topics SET opened=1 WHERE id=?', (tid,))
    chat_sessions.select(c, bid, tid)
    c.execute('UPDATE book_state SET active_id=? WHERE singleton=1', (bid,))
    c.execute('UPDATE books SET updated=CURRENT_TIMESTAMP WHERE id=?', (bid,))


def purge(c, bid):
    c.execute('INSERT OR IGNORE INTO retired_books VALUES(?)', (bid,))
    queue_vectors(c, 'WHERE person_id=?', (bid,))
    queue_audio(c, 'SELECT audio FROM messages WHERE person_id=?', (bid,))
    if interview.find(c, bid):
        c.execute('DELETE FROM book_interviews WHERE book_id=?', (bid,))
    c.execute("""INSERT OR IGNORE INTO book_cleanup SELECT 'share','',s.token_hash
        FROM shares s JOIN chapters ch ON ch.id=s.chapter_id WHERE ch.person_id=?""", (bid,))
    queries = (
        'DELETE FROM topic_drafts WHERE topic_id IN (SELECT id FROM book_topics WHERE book_id=?)',
        'DELETE FROM book_topics WHERE book_id=?',
        'DELETE FROM shares WHERE chapter_id IN (SELECT id FROM chapters WHERE person_id=?)',
        'DELETE FROM chapter_audio WHERE chapter_id IN (SELECT id FROM chapters WHERE person_id=?)',
        'DELETE FROM chapter_sources WHERE chapter_id IN (SELECT id FROM chapters WHERE person_id=?)',
        'DELETE FROM chapters WHERE person_id=?',
        'DELETE FROM memory_edges WHERE item_id IN (SELECT id FROM memory_items WHERE person_id=?)',
        'DELETE FROM memory_items WHERE person_id=?',
        'DELETE FROM memory_nodes WHERE person_id=?',
        'DELETE FROM memory_progress WHERE source_id IN (SELECT id FROM messages WHERE person_id=?)',
        'DELETE FROM chat_turns WHERE person_id=?',
        'DELETE FROM chat_session_messages WHERE session_id IN (SELECT id FROM chat_sessions WHERE person_id=?)',
        'DELETE FROM active_chat_session WHERE person_id=?',
        'DELETE FROM chat_sessions WHERE person_id=?',
        'DELETE FROM messages WHERE person_id=?',
        'DELETE FROM memory_settings WHERE person_id=?',
        'DELETE FROM books WHERE id=?',
        'DELETE FROM people WHERE id=?',
    )
    for query in queries:
        c.execute(query, (bid,))


def legacy(c):
    if managed(c):
        raise HTTPException(409, '这本书已改用分章创作，请更新 App')
