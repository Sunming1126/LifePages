import asyncio
import base64
import io
import json
import os
import tempfile
import unittest
import wave
from unittest.mock import patch

TEMP = tempfile.TemporaryDirectory()
os.environ['LIFEPAGES_DATA'] = TEMP.name
os.environ['LIFEPAGES_ACCESS_TOKEN'] = 'test-family-token-0123456789'
os.environ['LIFEPAGES_PUBLIC_BASE_URL'] = 'https://example.test/lifepages'
from server import app as backend
import httpx


def wav():
    data = io.BytesIO()
    with wave.open(data, 'wb') as f:
        f.setnchannels(1); f.setsampwidth(2); f.setframerate(16000); f.writeframes(b'\0\0' * 100)
    return base64.b64encode(data.getvalue()).decode()


class FlowTest(unittest.IsolatedAsyncioTestCase):
    async def test_streaming_model_reuses_client_until_api_shutdown(self):
        prompts = []

        def reply(request):
            prompts.append(json.loads(request.content)['messages'][-1]['content'])
            return httpx.Response(200, text=(
                'data: {"choices":[{"delta":{"content":"收到"},"finish_reason":"stop"}]}\n'
                'data: [DONE]\n'
            ))

        provider = httpx.AsyncClient(transport=httpx.MockTransport(reply))
        config = ('test-key', 'https://model.example.test/v1', 'test-model')
        with patch.object(backend, 'read_llm_config', return_value=config), \
                patch.object(backend.httpx, 'AsyncClient', return_value=provider) as client_factory:
            async with backend.lifespan(backend.app):
                for prompt in ('虚构测试一', '虚构测试二'):
                    self.assertEqual([text async for text in backend.stream_llm('测试', prompt)], ['收到'])
                    self.assertFalse(provider.is_closed)
            client_factory.assert_called_once()
        self.assertTrue(provider.is_closed)
        self.assertEqual(prompts, ['虚构测试一', '虚构测试二'])

    async def test_bailian_chapter_json_requests_disable_thinking(self):
        def reply(request):
            body = json.loads(request.content)
            self.assertEqual(body['response_format'], {'type': 'json_object'})
            self.assertIs(body['enable_thinking'], False)
            return httpx.Response(200, json={'choices': [
                {'finish_reason': 'stop', 'message': {'content': '{"body":"","source_ids":[]}'}}
            ]})

        transport = httpx.MockTransport(reply)
        provider = httpx.AsyncClient(transport=transport)
        config = ('test-key', 'https://dashscope.aliyuncs.com/compatible-mode/v1', 'qwen3.7-flash')
        with patch.object(backend, 'read_llm_config', return_value=config), \
                patch.object(backend.httpx, 'AsyncClient', return_value=provider):
            result = await backend.llm('只输出 JSON', '虚构讲述', json_mode=True)
        self.assertEqual(json.loads(result), {'body': '', 'source_ids': []})

    async def asyncSetUp(self):
        self.client = httpx.AsyncClient(transport=httpx.ASGITransport(app=backend.app), base_url='http://test')
        token = (await self.client.post('/api/bootstrap')).json()['token']
        self.client.headers['Authorization'] = 'Bearer ' + token
    async def asyncTearDown(self):
        await self.client.aclose()

    async def test_stream_turn_publishes_speech_before_completion_and_retries_once(self):
        pid = (await self.client.get('/api/current-person')).json()['id']
        turn = {'request_id': 'd' * 32, 'text': '院子里的星星', 'speak': True}
        path = f'/api/people/{pid}/turns/stream'

        async def deltas(*_):
            yield '小时候在院子里看星星，'
            with backend.closing(backend.db()) as c:
                row = c.execute('SELECT text FROM rtc_turn_segments WHERE request_id=?',
                                (turn['request_id'],)).fetchone()
                self.assertEqual(row['text'], '小时候在院子里看星星，')
                self.assertIsNone(c.execute('SELECT assistant_id FROM chat_turns').fetchone()[0])
            yield '那画面很美。'

        with patch.object(backend, 'stream_llm', deltas):
            result = await self.client.post(path, json=turn)
        self.assertEqual(result.headers['x-accel-buffering'], 'no')
        events = [json.loads(line) for line in result.text.splitlines()]
        self.assertEqual([e['type'] for e in events], ['delta', 'speech', 'delta', 'speech', 'done'])
        self.assertEqual(events[-1]['text'], '小时候在院子里看星星，那画面很美。')
        retry = await self.client.post(path, json=turn)
        self.assertEqual([json.loads(line) for line in retry.text.splitlines()], [events[-1]])

    async def test_story_shares_and_revoke(self):
        r = await self.client.post('/api/people', json={'name': '奶奶', 'background': '故乡'})
        self.assertEqual(r.status_code, 200)
        pid = r.json()['id']
        r = await self.client.post(f'/api/people/{pid}/answers', json={'text': '我小时候住在海边', 'audio_base64': wav()})
        self.assertEqual(r.status_code, 200)
        mid = r.json()['id']
        async def fake_llm(system, context):
            return '{"title":"海边的童年","content":"我小时候住在海边。"}'
        with patch.object(backend, 'llm', fake_llm):
            r = await self.client.post(f'/api/people/{pid}/chapters/generate')
            self.assertEqual(r.status_code, 200)
            cid = r.json()['id']
            self.assertEqual((await self.client.post(f'/api/people/{pid}/chapters/generate')).status_code, 400)
            await self.client.post(f'/api/people/{pid}/answers', json={'text': '后来我去了山里'})
            self.assertEqual((await self.client.post(f'/api/people/{pid}/chapters/generate')).status_code, 200)
        r = await self.client.post(f'/api/chapters/{cid}/share')
        self.assertTrue(r.json()['url'].startswith('https://example.test/lifepages/listen/'))
        token = r.json()['url'].rsplit('/', 1)[-1]
        page = await self.client.get(f'/listen/{token}')
        self.assertEqual(page.status_code, 200)
        self.assertIn(f'https://example.test/lifepages/listen/{token}/audio/{mid}', page.text)
        self.assertEqual((await self.client.get(f'/listen/{token}/audio/{mid}')).status_code, 200)
        await self.client.delete(f'/api/chapters/{cid}/shares')
        self.assertEqual((await self.client.get(f'/listen/{token}')).status_code, 404)
        self.assertEqual((await self.client.get(f'/listen/{token}/audio/{mid}')).status_code, 404)

    async def test_chat_retry_and_idempotency(self):
        person = (await self.client.get('/api/current-person')).json()
        pid = person['id']
        turn = {'request_id': 'a' * 32, 'text': '海边的童年很快乐', 'audio_base64': wav()}
        path = f'/api/people/{pid}/turns'
        calls = []
        def reject(request):
            calls.append(request.url.path)
            return httpx.Response(429, json={'error': {
                'code': 'AccountQuotaExceeded',
                'message': 'It will reset at 2026-11-10 06:08:26 +0000 UTC. Request id: upstream-private',
            }})
        provider = httpx.AsyncClient(transport=httpx.MockTransport(reject))
        with patch.object(backend, 'read_llm_config', return_value=('test-key', 'https://model.test', 'test-model')), \
             patch.object(backend.httpx, 'AsyncClient', return_value=provider):
            response = await self.client.post(path, json=turn)
        self.assertEqual(response.status_code, 429)
        self.assertEqual(response.json()['detail'], 'AI 回复额度暂时用完，请在北京时间 11月10日 14:08:26 后点击重试。')
        saved = (await self.client.get(f'/api/people/{pid}')).json()['messages']
        self.assertEqual(len(saved), 1)
        self.assertEqual(saved[0]['role'], 'user')
        self.assertEqual(saved[0]['has_audio'], 1)
        self.assertEqual(saved[0]['request_id'], turn['request_id'])
        self.assertEqual((await self.client.get('/api/messages/' + saved[0]['id'] + '/audio')).status_code, 200)
        async def success(system, context):
            calls.append(context)
            await asyncio.sleep(.01)
            return '听起来海边给您留下了美好回忆。'
        with patch.object(backend, 'llm', success):
            responses = await asyncio.gather(self.client.post(path, json=turn), self.client.post(path, json=turn))
            self.assertEqual([r.status_code for r in responses], [200, 200])
            self.assertEqual(responses[0].json(), responses[1].json())
            conflict = dict(turn, text='另一段内容')
            self.assertEqual((await self.client.post(path, json=conflict)).status_code, 409)
        self.assertEqual(len(calls), 2)
        messages = (await self.client.get(f'/api/people/{pid}')).json()['messages']
        self.assertEqual([m['role'] for m in messages], ['user', 'assistant'])

    async def test_new_concurrent_turn_has_one_user_and_reply(self):
        pid = (await self.client.get('/api/current-person')).json()['id']
        payload = {'request_id': 'b' * 32, 'text': '并发测试', 'audio_base64': wav()}
        path = f'/api/people/{pid}/turns'
        calls = []
        async def respond(system, context):
            calls.append(1)
            await asyncio.sleep(.02)
            return '回应'
        with patch.object(backend, 'llm', respond):
            a, b = await asyncio.gather(self.client.post(path, json=payload), self.client.post(path, json=payload))
        self.assertEqual(a.status_code, 200)
        self.assertEqual(a.json(), b.json())
        self.assertEqual(len(calls), 1)
        messages = (await self.client.get(f'/api/people/{pid}')).json()['messages']
        self.assertEqual([m['role'] for m in messages], ['user', 'assistant'])
        self.assertEqual(messages[0]['request_id'], payload['request_id'])
        self.assertIsNone(messages[1]['request_id'])

    async def test_accounts_can_generate_at_the_same_time_without_sharing_context_or_audio(self):
        second = {'Authorization': 'Bearer ' + (await self.client.post('/api/bootstrap')).json()['token']}
        first = dict(self.client.headers)
        people = [
            (await self.client.get('/api/current-person', headers=headers)).json()['id']
            for headers in (first, second)
        ]
        lines = ('第一家独有的旧桥故事', '第二家独有的果园故事')
        arrived = set()
        both_running = asyncio.Event()

        async def respond(_system, context):
            own = [line for line in lines if line in context]
            self.assertEqual(len(own), 1)
            arrived.add(own[0])
            if len(arrived) == 2:
                both_running.set()
            await asyncio.wait_for(both_running.wait(), timeout=3)
            return own[0]

        with patch.object(backend, 'llm', respond):
            responses = await asyncio.gather(*(
                self.client.post(f'/api/people/{pid}/turns', headers=headers,
                                 json={'request_id': 'e' * 32, 'text': line, 'audio_base64': wav()})
                for pid, headers, line in zip(people, (first, second), lines)
            ))
        for response, headers, other, line in zip(responses, (first, second), (second, first), lines):
            self.assertEqual(response.status_code, 200, response.text)
            self.assertEqual(response.json()['text'], line)
            audio = '/api/messages/' + response.json()['user_id'] + '/audio'
            self.assertEqual((await self.client.get(audio, headers=headers)).status_code, 200)
            self.assertEqual((await self.client.get(audio, headers=other)).status_code, 404)

    async def test_current_person_preserves_existing_and_update(self):
        first = (await self.client.post('/api/people', json={'name': '奶奶'})).json()['id']
        second = (await self.client.post('/api/people', json={'name': '爷爷'})).json()['id']
        await self.client.post(f'/api/people/{first}/answers', json={'text': '原来的记录'})
        self.assertEqual((await self.client.get('/api/current-person')).json()['id'], first)
        self.assertEqual((await self.client.put(f'/api/people/{first}', json={'name': '外婆', 'background': '家乡'})).status_code, 200)
        self.assertEqual((await self.client.get(f'/api/people/{first}')).json()['name'], '外婆')
        self.assertEqual((await self.client.get(f'/api/people/{second}')).status_code, 200)
        legacy = (await self.client.get(f'/api/people/{first}')).json()['messages']
        self.assertIsNone(legacy[0]['request_id'])

    async def test_voice_temporary_token_is_private_and_cached(self):
        import time
        token_response = {'token': 'st-test-temporary', 'expires_at': int(time.time()) + 120}
        class Reply:
            def raise_for_status(self): pass
            def json(self): return token_response
        class Client:
            async def __aenter__(self): return self
            async def __aexit__(self, *args): pass
            async def post(self, *args, **kwargs):
                self.calls += 1
                return Reply()
            calls = 0
        provider = Client()
        # Keep the ASGI transport client real; only replace the provider factory.
        with patch.dict(os.environ, {'DASHSCOPE_API_KEY': 'server-only'}), patch.object(backend.httpx, 'AsyncClient', return_value=provider):
            first = await self.client.post('/api/voice/token')
            second = await self.client.post('/api/voice/token')
            unauthorized = await self.client.post('/api/voice/token', headers={'Authorization': 'Bearer bad'})
        self.assertEqual(first.status_code, 200)
        self.assertEqual(first.json(), token_response)
        self.assertEqual(first.headers['cache-control'], 'no-store')
        self.assertEqual(first.json(), second.json())
        self.assertEqual(provider.calls, 1)
        self.assertEqual(unauthorized.status_code, 401)

    async def test_memoir_overview_excludes_chat_body_and_is_account_private(self):
        pid=(await self.client.get('/api/current-person')).json()['id']
        other=(await self.client.post('/api/people',json={'name':'另一位讲述者'})).json()['id']
        await self.client.post(f'/api/people/{pid}/answers',json={'text':'私密聊天正文不应随我的页面下载','audio_base64':wav()})
        await self.client.post(f'/api/people/{other}/answers',json={'text':'另一位的故事'})
        response=await self.client.get(f'/api/people/{pid}/memoir')
        self.assertEqual(response.status_code,200)
        value=response.json()
        self.assertEqual(value['person']['id'],pid)
        self.assertEqual(value['stats'],{'stories':1,'recordings':1,'chapters':0})
        self.assertEqual(len(value['people']),2)
        self.assertNotIn('messages',value)
        self.assertNotIn('私密聊天正文',response.text)
        stranger=(await self.client.post('/api/bootstrap')).json()['token']
        self.assertEqual((await self.client.get(f'/api/people/{pid}/memoir',headers={'Authorization':'Bearer '+stranger})).status_code,404)

    async def test_authorization_and_invalid_audio(self):
        self.assertEqual((await self.client.get('/api/people', headers={'Authorization': 'Bearer bad'})).status_code, 401)
        await self.client.post('/api/people', json={'name': '甲'})
        other = (await self.client.post('/api/bootstrap')).json()['token']
        isolated = await self.client.get('/api/people', headers={'Authorization': 'Bearer ' + other})
        self.assertEqual(isolated.json(), [])
        r = await self.client.post('/api/transcribe', json={'audio_base64': 'not audio'})
        self.assertEqual(r.status_code, 400)

class VoiceSocketTest(unittest.TestCase):
    def test_relay_auth_and_final(self):
        from fastapi.testclient import TestClient
        from starlette.websockets import WebSocketDisconnect
        class Cloud:
            async def __aenter__(self):
                self.queue = asyncio.Queue()
                return self
            async def __aexit__(self, *args): pass
            async def send(self, value):
                if isinstance(value, str):
                    action = json.loads(value)['header']['action']
                    if action == 'run-task': await self.queue.put(json.dumps({'header': {'event':'task-started'}}))
                    elif action == 'finish-task':
                        await self.queue.put(json.dumps({'header': {'event':'result-generated'}, 'payload': {'output': {'sentence': {'sentence_id': 0, 'text': '你好'}}}}))
                        await self.queue.put(json.dumps({'header': {'event':'task-finished'}}))
            async def recv(self): return await self.queue.get()
        import json
        with TestClient(backend.app) as client:
            with self.assertRaises(WebSocketDisconnect):
                with client.websocket_connect('/api/voice/stream'):
                    pass
            token = client.post('/api/bootstrap').json()['token']
            with patch.dict(os.environ, {'DASHSCOPE_API_KEY': 'fake'}), patch.object(backend.websockets, 'connect', return_value=Cloud()):
                with client.websocket_connect('/api/voice/stream', headers={'Authorization': 'Bearer ' + token}) as ws:
                    self.assertEqual(ws.receive_json()['type'], 'ready')
                    ws.send_bytes(b'\0\0' * 100)
                    ws.send_json({'type': 'finish'})
                    self.assertEqual(ws.receive_json(), {'type': 'partial', 'text': '你好'})
                    self.assertEqual(ws.receive_json(), {'type': 'final', 'text': '你好'})

if __name__ == '__main__': unittest.main()
