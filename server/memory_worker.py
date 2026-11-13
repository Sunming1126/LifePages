"""Bounded backfill and vector sync. Run periodically, independently of drafts."""
from __future__ import annotations

import asyncio
import fcntl
import json
import time
from contextlib import closing

from server import app as backend, account_profile
from server import book_api, book_store as books, memory
from server.memory_vectors import VectorIndex


def snapshot(pid):
    with closing(backend.db()) as c:
        c.executescript(memory.SCHEMA)
        books.active(c, pid)
        enabled, epoch = memory.settings(c)
        if not enabled or not account_profile.background_ai(c):
            return epoch, []
        rows = c.execute('''SELECT m.id,m.text FROM messages m
            LEFT JOIN memory_progress p ON p.source_id=m.id
            WHERE m.person_id=? AND m.role='user' AND COALESCE(p.done,0)=0
            AND COALESCE(p.retry_at,0)<=? ORDER BY m.rowid DESC LIMIT 8''',
            (pid, int(time.time())))
        chosen, size = [], 0
        for row in rows:
            if chosen and size + len(row['text']) > 12_000:
                break
            chosen.append(dict(row))
            size += len(row['text'])
    return epoch, chosen


def commit(pid, epoch, rows, items):
    with closing(backend.db()) as c, c:
        c.execute('BEGIN IMMEDIATE')
        books.active(c, pid)
        if memory.settings(c) != (True, epoch) or not account_profile.background_ai(c):
            return False
        for row in rows:
            if c.execute('SELECT 1 FROM memory_progress WHERE source_id=? AND done=1', (row['id'],)).fetchone():
                return False
        for item in items:
            memory.store(c, pid, item)
        c.executemany('''INSERT INTO memory_progress(source_id,done) VALUES(?,1)
            ON CONFLICT(source_id) DO UPDATE SET done=1''', [(row['id'],) for row in rows])
    return True


def retry(pid, epoch, rows):
    with closing(backend.db()) as c, c:
        c.execute('BEGIN IMMEDIATE')
        books.active(c, pid)
        if memory.settings(c) != (True, epoch) or not account_profile.background_ai(c):
            return
        now = int(time.time())
        c.executemany('''INSERT INTO memory_progress(source_id,attempts,retry_at) VALUES(?,1,?)
            ON CONFLICT(source_id) DO UPDATE SET attempts=attempts+1,
            retry_at=? + MIN(3600,60 * (1 << MIN(attempts+1,6))) WHERE done=0''',
            [(row['id'], now + 120, now) for row in rows])


async def extract(pid):
    epoch, rows = snapshot(pid)
    if not rows:
        return 'idle'
    # Never send audio or assistant text to the extraction model.
    try:
        result = await backend.llm(memory.EXTRACTION_PROMPT, json.dumps(rows, ensure_ascii=False))
        items = memory.parse_extraction(result, rows)
    except Exception:
        retry(pid, epoch, rows)
        return 'retry'
    return 'processed' if commit(pid, epoch, rows, items) else 'changed'


async def sync(account, pid, index):
    if not index.url:
        return
    with closing(backend.db()) as c:
        enabled, _ = memory.settings(c)
        rows = [dict(row) for row in c.execute('''SELECT id, title, content, tags, revision, status FROM memory_items
            WHERE person_id=? AND (status='deleted' OR ?)
            AND (revision!=indexed_revision OR index_key!=?)
            ORDER BY (status='deleted') DESC, rowid LIMIT 16''',
            (pid, enabled and account_profile.background_ai(c), index.key))]
    if not rows:
        return
    await index.sync(account, pid, rows)
    with closing(backend.db()) as c, c:
        c.executemany('UPDATE memory_items SET indexed_revision=?,index_key=? WHERE id=? AND revision=?',
                      [(row['revision'], index.key, row['id'], row['revision']) for row in rows])


async def run_once():
    counts = dict(processed=0, changed=0, idle=0, retry=0, failed=0, index_failed=0)
    index = VectorIndex()
    with closing(backend.registry()) as c:
        accounts = [row['id'] for row in c.execute('SELECT id FROM accounts ORDER BY rowid')]
    for account in accounts:
        token = backend.ACCOUNT.set(account)
        try:
            await book_api.maintain(account)
            with closing(backend.db()) as c:
                if books.managed(c):
                    people = [row[0] for row in c.execute('SELECT id FROM books WHERE deleted_at IS NULL')]
                else:
                    people = [row['id'] for row in c.execute('SELECT id FROM people ORDER BY rowid')]
            for pid in people:
                try:
                    for _ in range(3):
                        outcome = await extract(pid)
                        counts[outcome] += 1
                        if outcome != 'processed':
                            break
                except Exception:
                    counts['failed'] += 1
                try:
                    await sync(account, pid, index)
                except Exception:
                    counts['index_failed'] += 1
        except Exception:
            counts['failed'] += 1
        finally:
            backend.ACCOUNT.reset(token)
    return counts


def main():
    with (backend.DATA / 'memory-worker.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return
        counts = asyncio.run(run_once())
        print(' '.join(f'{key}={value}' for key, value in counts.items()))


if __name__ == '__main__':
    main()
