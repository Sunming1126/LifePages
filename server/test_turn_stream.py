import asyncio
import json
import unittest
from unittest.mock import patch

from fastapi import HTTPException
from server.turn_stream import events_with_progress
from server.test_app import backend, httpx


class ProgressTests(unittest.IsolatedAsyncioTestCase):
    async def test_pending_model_keeps_stream_alive_and_keeps_one_anext(self):
        release = asyncio.Event()
        calls = 0
        async def source():
            nonlocal calls
            calls += 1
            await release.wait()
            yield {'type': 'done', 'text': '真实模型结果'}
        stream = events_with_progress(source(), 'synthetic', heartbeat=.005, budget=1)
        self.assertEqual(await anext(stream), {'type': 'processing'})
        self.assertEqual(await anext(stream), {'type': 'processing'})
        self.assertEqual(calls, 1)
        release.set()
        self.assertEqual((await anext(stream))['text'], '真实模型结果')
        await stream.aclose()

    async def test_disconnection_cancels_pending_model_and_releases_resources(self):
        closed = asyncio.Event()
        async def source():
            try:
                await asyncio.Event().wait()
                yield {}
            finally:
                closed.set()
        stream = events_with_progress(source(), 'synthetic', heartbeat=.005, budget=1)
        await anext(stream)
        await stream.aclose()
        self.assertTrue(closed.is_set())

    async def test_hard_deadline_stops_heartbeat_and_cancels_hung_call(self):
        closed = asyncio.Event()
        async def source():
            try:
                await asyncio.Event().wait()
                yield {}
            finally:
                closed.set()
        with self.assertRaises(HTTPException) as caught:
            async for _ in events_with_progress(source(), 'synthetic', heartbeat=.005, budget=.02):
                pass
        self.assertEqual(caught.exception.status_code, 504)
        self.assertTrue(closed.is_set())

    async def test_turn_retry_after_deadline_uses_same_original_once(self):
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=backend.app), base_url='http://test') as client:
            token = (await client.post('/api/bootstrap')).json()['token']
            client.headers['Authorization'] = 'Bearer ' + token
            pid = (await client.get('/api/current-person')).json()['id']
            turn = {'request_id': 'acef' * 8, 'text': '虚构：小时候在院子里看星星。', 'speak': False}
            async def stuck(*_):
                await asyncio.Event().wait()
                yield ''
            with patch.object(backend, 'stream_llm', stuck), \
                 patch('server.turn_stream.HEARTBEAT_SECONDS', .005), \
                 patch('server.turn_stream.MAX_TURN_SECONDS', .02):
                response = await client.post(f'/api/people/{pid}/turns/stream', json=turn)
            events = [json.loads(line) for line in response.text.splitlines()]
            self.assertIn('processing', [e['type'] for e in events])
            self.assertEqual(events[-1]['status'], 504)
            async def recovered(*_):
                yield '那天的星星很亮。'
            with patch.object(backend, 'stream_llm', recovered):
                retry = await client.post(f'/api/people/{pid}/turns/stream', json=turn)
            final = json.loads(retry.text.splitlines()[-1])
            self.assertEqual(final['type'], 'done')
            backend.authorized('Bearer ' + token)
            with backend.closing(backend.db()) as c:
                self.assertEqual(c.execute('SELECT COUNT(*) FROM messages WHERE person_id=? AND role=\'user\'', (pid,)).fetchone()[0], 1)
                self.assertEqual(c.execute('SELECT COUNT(*) FROM messages WHERE person_id=? AND role=\'assistant\'', (pid,)).fetchone()[0], 1)
