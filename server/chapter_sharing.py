"""Render the published chapter and pair its permitted audio with interview prompts."""
import html
import re

from server import book_store as books, chat_sessions


def has_table(c, name):
    return c.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (name,)).fetchone() is not None


def extract_question(text):
    return ' '.join(part.strip() for part in re.findall(r'[^。！？!?\n]*[？?]', text))


def preceding_question(c, pid, sid, sequence):
    query = """SELECT m.rowid,m.role,m.text FROM messages m WHERE m.person_id=?
        AND m.rowid<? AND m.role IN ('user','assistant')"""
    params = (pid, sequence)
    if has_table(c, 'chat_session_messages'):
        query += f' AND {chat_sessions.scope("m")}=?'
        params += (sid,)
    previous = c.execute(query + ' ORDER BY m.rowid DESC LIMIT 1', params).fetchone()
    if not previous or previous['role'] != 'assistant':
        return ''
    question = extract_question(previous['text'])
    if question or sid == pid or not has_table(c, 'book_topics'):
        return question
    opening = c.execute('''SELECT 1 FROM book_topics t WHERE t.id=? AND t.book_id=?
        AND NOT EXISTS (SELECT 1 FROM chat_session_messages sm JOIN messages m ON m.id=sm.message_id
                        WHERE sm.session_id=t.id AND m.rowid<?)''', (sid, pid, previous['rowid'])).fetchone()
    return previous['text'].strip() if opening else ''


def save_question(c, mid, question):
    c.execute('''CREATE TABLE IF NOT EXISTS recording_questions (
        message_id TEXT PRIMARY KEY REFERENCES messages(id) ON DELETE CASCADE,
        question TEXT NOT NULL)''')
    c.execute('INSERT OR IGNORE INTO recording_questions VALUES(?,?)', (mid, question))


def remember_question(c, pid, sid, mid):
    sequence = c.execute('SELECT rowid FROM messages WHERE id=?', (mid,)).fetchone()[0]
    save_question(c, mid, preceding_question(c, pid, sid, sequence))


def preserve_before_refresh(c, pid, sid, sequence, text, *, opening):
    following = c.execute('''SELECT m.id,m.role,m.audio FROM chat_session_messages sm
        JOIN messages m ON m.id=sm.message_id WHERE sm.session_id=? AND m.person_id=?
        AND m.rowid>? AND m.role IN ('assistant','user') ORDER BY m.rowid LIMIT 1''',
        (sid, pid, sequence)).fetchone()
    if following and following['role'] == 'user' and following['audio']:
        save_question(c, following['id'], extract_question(text) or (text.strip() if opening else ''))


def recording_question(c, chapter, topic_id, mid):
    if has_table(c, 'recording_questions'):
        saved = c.execute('SELECT question FROM recording_questions WHERE message_id=?', (mid,)).fetchone()
        if saved is not None:
            return saved['question']
    pid = chapter['person_id']
    recording = c.execute("SELECT rowid FROM messages WHERE id=? AND person_id=? AND role='user'",
                          (mid, pid)).fetchone()
    if not recording:
        return ''
    session = None
    if has_table(c, 'chat_session_messages'):
        session = c.execute('SELECT session_id FROM chat_session_messages WHERE message_id=?', (mid,)).fetchone()
    sid = session['session_id'] if session else pid
    if topic_id is not None and sid != topic_id:
        return ''
    return preceding_question(c, pid, sid, recording[0])


def manuscript(c, chapter):
    if has_table(c, 'book_topics'):
        topic = c.execute('SELECT id,chapter_id FROM book_topics WHERE chapter_id=? AND book_id=?',
                          (chapter['id'], chapter['person_id'])).fetchone()
        if topic is not None:
            if has_table(c, 'topic_manuscripts'):
                return topic['id'], books.get_blocks(c, topic)
            return topic['id'], [{'kind': 'text', 'text': chapter['content']}]
    return None, [{'kind': 'text', 'text': chapter['content']}]


def render(title, listen_url, blocks, recordings):
    base = html.escape(listen_url, quote=True)
    content = []
    for block in blocks:
        if block['kind'] == 'text':
            content.extend(f'<p>{html.escape(line)}</p>'
                           for line in block['text'].splitlines() if line.strip())
        elif block['kind'] == 'image':
            iid = html.escape(block['image_id'], quote=True)
            content.append(f'<figure><img src="{base}/image/{iid}" alt="章节图片" loading="lazy"></figure>')
    players = []
    for index, (mid, question) in enumerate(recordings, 1):
        prompt = f'提问 · {html.escape(question)}' if question else '暂无对应提问'
        players.append(f'<li><h3>第 {index} 段</h3><p>{prompt}</p>'
                       f'<audio aria-label="第 {index} 段原声" controls preload="none" '
                       f'src="{base}/audio/{html.escape(mid, quote=True)}"></audio></li>')
    safe_title = html.escape(title)
    prose = ''.join(content) or '<p>本章暂未整理正文。</p>'
    audio = f'<ol>{"".join(players)}</ol>' if players else '<p>本章暂无原声录音。</p>'
    return f'''<!doctype html>
<html lang="zh-CN">
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="referrer" content="no-referrer">
<title>{safe_title} · 原声回忆</title>
<style>
  body {{ margin:0 auto; max-width:42rem; padding:2.5rem 1.25rem; background:#f7f2e9;
    color:#302b25; font:18px/1.7 system-ui,sans-serif; overflow-wrap:anywhere; }}
  h1,h2,h3 {{ line-height:1.3; }} h1 {{ font-size:clamp(1.8rem,7vw,2.75rem); }}
  h2 {{ font-size:1.3rem; margin:2rem 0 .9rem; }}
  h3 {{ margin:0; font-size:.95rem; color:#745832; }}
  article,li {{ background:#fffcf7; border:1px solid #e7ded0; border-radius:16px; padding:1.1rem; }}
  p {{ margin:.6rem 0 1rem; }} article p:last-child {{ margin-bottom:.5rem; }}
  ol {{ padding:0; list-style:none; }} li {{ margin-bottom:.8rem; }}
  audio {{ width:100%; display:block; }}
  figure {{ margin:1rem 0; }} img {{ display:block; width:100%; height:auto; border-radius:10px; }}
</style>
<main>
  <h1>{safe_title}</h1>
  <section aria-labelledby="chapter-heading">
    <h2 id="chapter-heading">章节正文</h2>
    <article>{prose}</article>
  </section>
  <section aria-labelledby="audio-heading">
    <h2 id="audio-heading">原声回听</h2>
    {audio}
  </section>
</main>
</html>'''
