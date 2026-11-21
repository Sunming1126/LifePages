"""Non-blocking chapter adoption. Completed, unclaimed evidence is the durable queue."""
import asyncio
import json
import time
from contextlib import closing

from server import app as backend, book_api, book_store as books, interview, interview_api, interview_v2

_tasks = {}
_failures = {}


def material(c, bid):
    state = interview.find(c, bid)
    if state is None or state['version'] != 2:
        return []
    return interview_api.draft_material(c, bid)


def schedule(c, bid):
    key = (backend.ACCOUNT.get(), bid)
    task = _tasks.get(key)
    if task is not None and not task.done():
        return {'organizing': True}
    if not material(c, bid):
        _failures.pop(key, None)
        return {'organizing': False}
    if time.monotonic() - _failures.get(key, -1000) < 30:
        return {'organizing': False, 'organization_error': '本章自动整理暂未完成，稍后打开会重试；原话仍已保存。'}
    task = asyncio.create_task(run(bid))
    _tasks[key] = task
    def finished(done):
        if _tasks.get(key) is done:
            _tasks.pop(key, None)
    task.add_done_callback(finished)
    return {'organizing': True}


async def run(bid):
    key = (backend.ACCOUNT.get(), bid)
    try:
        for _ in range(30):
            with closing(backend.db()) as c:
                books.active(c, bid)
                available = material(c, bid)
                if not available:
                    _failures.pop(key, None)
                    return
                number = available[0]['numbers'][0]
                chosen = [p for p in available if p['numbers'] == [number]]
                existing = interview_api.existing_chapters(c, bid)
            proposals = await interview_api.generate_theme_chapters(chosen, existing)
            lock = backend._turn_locks.setdefault(f'{key[0]}:{bid}', asyncio.Lock())
            async with lock:
                with closing(backend.db()) as c, c:
                    c.execute('BEGIN IMMEDIATE')
                    books.active(c, bid)
                    fresh = [p for p in material(c, bid) if p['numbers'] == [number]]
                    if chosen != fresh:
                        continue
                    withheld = interview_v2.withheld_recordings(c, bid)
                    for proposal in proposals:
                        interview_api.adopt(c, bid, proposal,
                            interview_api.ChapterEdit(title=proposal['title'], body=proposal['body']), withheld)
                    # A previously previewed whole-book proposal now includes claimed passages.
                    c.execute('DELETE FROM interview_drafts WHERE book_id=? AND saved=0', (bid,))
                    c.execute('UPDATE books SET updated=CURRENT_TIMESTAMP WHERE id=?', (bid,))
    except asyncio.CancelledError:
        raise  # Unclaimed evidence survives process shutdown and resumes on reopen.
    except Exception:
        _failures[key] = time.monotonic()
