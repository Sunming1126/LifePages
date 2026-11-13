"""Chat grouping. Unmapped legacy messages belong to the narrator's original chat."""
SCHEMA = """
CREATE TABLE IF NOT EXISTS chat_sessions(
    id TEXT PRIMARY KEY, person_id TEXT NOT NULL REFERENCES people(id),
    title TEXT NOT NULL, updated TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS chat_sessions_person ON chat_sessions(person_id);
CREATE TABLE IF NOT EXISTS chat_session_messages(
    message_id TEXT PRIMARY KEY REFERENCES messages(id),
    session_id TEXT NOT NULL REFERENCES chat_sessions(id)
);
CREATE INDEX IF NOT EXISTS chat_session_messages_session ON chat_session_messages(session_id);
CREATE TABLE IF NOT EXISTS active_chat_session(
    person_id TEXT PRIMARY KEY REFERENCES people(id),
    session_id TEXT NOT NULL REFERENCES chat_sessions(id)
);
"""


def scope(alias):
    return f"""COALESCE((SELECT session_id FROM chat_session_messages
        WHERE message_id={alias}.id),{alias}.person_id)"""


def messages_for(c, pid, sid=None):
    source, condition, args = 'messages m', '', (pid,)
    if sid is not None:
        args = (pid, sid)
        if sid == pid:
            condition = f'AND {scope("m")}=?'
        else:
            source = 'chat_session_messages sm JOIN messages m ON m.id=sm.message_id'
            condition = 'AND sm.session_id=?'
    return [dict(row) for row in c.execute(f'''SELECT m.id,m.role,m.text,m.created,
        m.audio IS NOT NULL AS has_audio,t.request_id FROM {source}
        LEFT JOIN chat_turns t ON t.user_id=m.id
        WHERE m.person_id=? AND m.role IN ('user','assistant') {condition}
        ORDER BY m.rowid''', args)]


def ensure_default(c, pid):
    c.execute('''INSERT OR IGNORE INTO chat_sessions(id,person_id,title,updated)
        VALUES(?,?, '原有对话', COALESCE((SELECT MAX(created) FROM messages WHERE person_id=?),
        CURRENT_TIMESTAMP))''', (pid, pid, pid))


def active(c, pid):
    row = c.execute('SELECT session_id FROM active_chat_session WHERE person_id=?', (pid,)).fetchone()
    return row['session_id'] if row else pid


def select(c, pid, sid):
    c.execute('''INSERT INTO active_chat_session VALUES(?,?)
        ON CONFLICT(person_id) DO UPDATE SET session_id=excluded.session_id''', (pid, sid))


def bind(c, pid, sid, mid):
    if sid != pid:
        c.execute('INSERT INTO chat_session_messages VALUES(?,?)', (mid, sid))
    c.execute('UPDATE chat_sessions SET updated=CURRENT_TIMESTAMP WHERE id=?', (sid,))


def list_for(c, pid):
    return [dict(row) for row in c.execute('''WITH counts AS (
        SELECT ''' + scope('m') + ''' AS sid, COUNT(*) AS message_count, MAX(m.created) AS last_message
        FROM messages m WHERE m.person_id=? GROUP BY sid)
        SELECT s.id,s.title,MAX(s.updated,COALESCE(counts.last_message,s.updated)) AS updated,
            COALESCE(counts.message_count,0) AS message_count
        FROM chat_sessions s LEFT JOIN counts ON counts.sid=s.id
        WHERE s.person_id=? ORDER BY updated DESC,s.rowid DESC''', (pid, pid))]


def title_from_first_message(c, sid, text):
    title = ' '.join(text.split())
    if len(title) > 24:
        title = title[:24] + '…'
    c.execute('''UPDATE chat_sessions SET title=? WHERE id=? AND title='新对话'
        AND (SELECT COUNT(*) FROM chat_session_messages WHERE session_id=?)=1''', (title, sid, sid))
