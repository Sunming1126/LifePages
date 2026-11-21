"""Keep a pending turn alive without inventing reply text or hiding hung calls."""
import asyncio
import logging
from contextlib import aclosing

HEARTBEAT_SECONDS = 10
MAX_TURN_SECONDS = 90
logger = logging.getLogger(__name__)


async def events_with_progress(events, request_id, *, heartbeat=None, budget=None):
    heartbeat = HEARTBEAT_SECONDS if heartbeat is None else heartbeat
    budget = MAX_TURN_SECONDS if budget is None else budget
    loop = asyncio.get_running_loop()
    started = loop.time()
    deadline = started + budget
    pending = None
    warned = False
    async with aclosing(events):
        try:
            while True:
                if pending is None:
                    pending = asyncio.create_task(events.__anext__())
                remaining = deadline - loop.time()
                if remaining <= 0:
                    from fastapi import HTTPException
                    logger.warning('chat_turn_deadline request_id=%s elapsed=%.1f', request_id, loop.time() - started)
                    raise HTTPException(504, '这次回复处理时间较长，请点击重试。您的原话已保存，不会重复记录。')
                ready, _ = await asyncio.wait({pending}, timeout=min(heartbeat, remaining))
                if not ready:
                    elapsed = loop.time() - started
                    if elapsed >= 30 and not warned:
                        logger.warning('chat_turn_slow request_id=%s elapsed=%.1f', request_id, elapsed)
                        warned = True
                    yield {'type': 'processing'}
                    continue
                try:
                    event = pending.result()
                except StopAsyncIteration:
                    return
                pending = None
                yield event
        finally:
            if pending is not None:
                pending.cancel()
                await asyncio.gather(pending, return_exceptions=True)
