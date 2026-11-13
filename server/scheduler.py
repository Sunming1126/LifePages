"""Daily account-isolated memoir drafts, invoked by lifepages-drafts.timer.

No recordings or conversation text are written to logs. A chapter is only
committed if none of its source messages were claimed while the model ran.
"""
from __future__ import annotations

import asyncio
import fcntl
import json
import re
import sys
import uuid
from contextlib import closing

from server import app as backend, account_profile
from server import book_api, book_store as books

MIN_ANSWERS = 3
MIN_CHARACTERS = 100
MAX_CONTEXT_BYTES = 400_000

PROMPT = (
    '将下列真实对话中讲述者分享的人生经历整理成第一人称回忆录草稿。'
    '只使用讲述者明确说过的信息，保留其表达方式，不编造事实、对话、情绪或细节。'
    '日常闲聊若不包含足够的人生经历，不要牵强编造故事，返回 should_create=false。'
    '只输出 JSON 对象，包含布尔值 should_create 和字符串 title、content；'
    'content 使用自然段，不使用 Markdown。'
)


def load_snapshot(person_id):
    """Use the same source cursor as the manual chapter workflow."""
    with closing(backend.db()) as connection:
        connection.execute('''CREATE TABLE IF NOT EXISTS draft_scheduler_state (
            person_id TEXT PRIMARY KEY REFERENCES people(id), last_no_story INTEGER NOT NULL)''')
        if books.managed(connection) or not account_profile.background_ai(connection):
            return None
        person = connection.execute('SELECT * FROM people WHERE id=?', (person_id,)).fetchone()
        if person is None:
            return None
        state = connection.execute('SELECT last_no_story FROM draft_scheduler_state WHERE person_id=?',
                                   (person_id,)).fetchone()
        last = connection.execute('''SELECT COALESCE(MAX(messages.rowid),0)
            FROM chapter_sources JOIN messages ON messages.id=chapter_sources.message_id
            JOIN chapters ON chapters.id=chapter_sources.chapter_id
            WHERE chapters.person_id=?''', (person_id,)).fetchone()[0]
        rows = [dict(row) for row in connection.execute(
            'SELECT rowid AS message_seq,id,role,text,audio FROM messages WHERE person_id=? AND rowid>? ORDER BY rowid',
            (person_id, last),
        )]
    answers = [row for row in rows if row['role'] == 'user']
    nonspace_chars = sum(len(''.join(row['text'].split())) for row in answers)
    if len(answers) < MIN_ANSWERS or nonspace_chars < MIN_CHARACTERS:
        return None
    if state is not None and max(row['message_seq'] for row in answers) <= state['last_no_story']:
        return None
    # Process a bounded prefix, so unusually long histories don't become stuck.
    context_size = len((person['name'] + person['background']).encode('utf-8'))
    chosen = []
    for row in rows:
        size = len(row['text'].encode('utf-8')) + 32
        if chosen and context_size + size > MAX_CONTEXT_BYTES:
            break
        chosen.append(row)
        context_size += size
    return dict(person), chosen


def parse_draft(result):
    cleaned = re.sub(r'^```(?:json)?\s*|\s*```$', '', result.strip())
    parsed = json.loads(cleaned)
    if not isinstance(parsed, dict):
        raise ValueError('invalid draft')
    if not isinstance(parsed.get('should_create'), bool):
        raise ValueError('invalid draft decision')
    if not parsed['should_create']:
        return None
    title, content = parsed.get('title'), parsed.get('content')
    if not isinstance(title, str) or not isinstance(content, str):
        raise ValueError('invalid draft')
    title, content = title.strip(), content.strip()
    if not title or not content or len(title) > 200 or len(content) > 100_000:
        raise ValueError('invalid draft')
    return title, content


def commit_draft(person_id, messages, title, content):
    """Atomic compare-and-insert; shared with manual generation's contract."""
    answers = [message for message in messages if message['role'] == 'user']
    if not answers:
        return False
    with closing(backend.db()) as connection:
        try:
            connection.execute('BEGIN IMMEDIATE')
            if books.managed(connection) or not account_profile.background_ai(connection):
                return False
            # Check each ID directly; this also avoids SQLite's variable limit for
            # long interviews. Only committed messages are ever marked as used.
            for message in answers:
                consumed = connection.execute('''SELECT 1 FROM chapter_sources
                    JOIN chapters ON chapters.id=chapter_sources.chapter_id
                    WHERE chapters.person_id=? AND chapter_sources.message_id=? LIMIT 1''',
                    (person_id, message['id'])).fetchone()
                if consumed:
                    connection.rollback()
                    return False
            if connection.execute('SELECT 1 FROM people WHERE id=?', (person_id,)).fetchone() is None:
                connection.rollback()
                return False
            chapter_id = uuid.uuid4().hex
            position = connection.execute(
                'SELECT COALESCE(MAX(position),-1)+1 FROM chapters WHERE person_id=?', (person_id,),
            ).fetchone()[0]
            connection.execute('INSERT INTO chapters(id,person_id,title,content,position) VALUES(?,?,?,?,?)',
                               (chapter_id, person_id, title, content, position))
            connection.executemany('INSERT INTO chapter_sources(chapter_id,message_id) VALUES(?,?)',
                                   [(chapter_id, message['id']) for message in answers])
            connection.executemany('INSERT INTO chapter_audio(chapter_id,message_id) VALUES(?,?)',
                                   [(chapter_id, message['id']) for message in answers if message['audio']])
            connection.commit()
            return True
        except Exception:
            connection.rollback()
            raise


async def process_person(person_id):
    snapshot = load_snapshot(person_id)
    if snapshot is None:
        return 'insufficient'
    person, messages = snapshot
    history = '\n'.join(('讲述者：' if message['role'] == 'user' else 'AI：') + message['text']
                        for message in messages)
    context = f"称呼：{person['name']}\n背景：{person['background']}\n对话：\n{history}"
    draft = parse_draft(await backend.llm(PROMPT, context))
    if draft is None:
        # Avoid re-sending unchanged small talk to the model every day. This is
        # only a scheduling hint: messages remain unconsumed and included once
        # a later answer provides new material.
        last_seq = max(message['message_seq'] for message in messages if message['role'] == 'user')
        with closing(backend.db()) as connection:
            connection.execute('''INSERT INTO draft_scheduler_state(person_id,last_no_story) VALUES(?,?)
                ON CONFLICT(person_id) DO UPDATE SET last_no_story=MAX(last_no_story,excluded.last_no_story)''',
                (person_id, last_seq))
            connection.commit()
        return 'no_story'
    return 'created' if commit_draft(person_id, messages, *draft) else 'conflict'


async def run_once():
    counts = {'created': 0, 'insufficient': 0, 'no_story': 0, 'conflict': 0, 'failed': 0}
    with closing(backend.registry()) as connection:
        accounts = [row['id'] for row in connection.execute('SELECT id FROM accounts ORDER BY id')]
    for account in accounts:
        if not re.fullmatch(r'[0-9a-f]{32}', account):
            counts['failed'] += 1
            continue
        marker = backend.ACCOUNT.set(account)
        try:
            with closing(backend.db()) as connection:
                if not account_profile.background_ai(connection):
                    continue
                managed = books.managed(connection)
                topics = connection.execute('''SELECT t.book_id,t.id FROM book_topics t JOIN books b ON b.id=t.book_id
                    WHERE b.deleted_at IS NULL AND t.opened=1 ORDER BY t.number''').fetchall() if managed else []
                people = [row['id'] for row in connection.execute('SELECT id FROM people ORDER BY rowid')]
            if managed:
                for bid, tid in topics:
                    try:
                        counts[await book_api.make_draft(bid, tid, automatic=True)] += 1
                    except Exception:
                        counts['failed'] += 1
                continue
            for person in people:
                try:
                    outcome = await process_person(person)
                    counts[outcome] += 1
                except Exception:
                    # Model errors can contain provider details; don't log them or
                    # conversation content. Unused messages remain retryable.
                    counts['failed'] += 1
        except Exception:
            counts['failed'] += 1
        finally:
            backend.ACCOUNT.reset(marker)
    return counts


def main():
    lock_path = backend.DATA / 'draft-scheduler.lock'
    with lock_path.open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print('自动整理已在运行，跳过本次。', file=sys.stderr)
            return
        counts = asyncio.run(run_once())
        print('自动整理完成：' + ' '.join(f'{key}={value}' for key, value in counts.items()))


if __name__ == '__main__':
    main()
