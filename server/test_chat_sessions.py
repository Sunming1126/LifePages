import json
import unittest
import uuid
from unittest.mock import AsyncMock, patch

from server.test_app import backend, httpx, wav
from server import memory_worker


class SessionTests(unittest.IsolatedAsyncioTestCase):
    async def test_legacy_history_and_account_memory_across_sessions(self):
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=backend.app), base_url='http://test') as client:
            token = (await client.post('/api/bootstrap')).json()['token']
            client.headers['Authorization'] = f'Bearer {token}'
            await client.put('/api/profile/background-ai', json={'enabled': True})
            pid = (await client.get('/api/current-person')).json()['id']
            path = f'/api/people/{pid}'
            source = '我在青禾中学念书。'
            old = await client.post(path + '/answers', json={'text': source, 'audio_base64': wav()})
            mid = old.json()['id']
            initial = (await client.get(path + '/sessions')).json()
            self.assertEqual(initial['active_id'], pid)
            self.assertEqual(initial['sessions'][0]['message_count'], 1)

            sid = uuid.uuid4().hex
            for _ in range(2):
                self.assertEqual((await client.post(path + '/sessions', json={'id': sid})).status_code, 200)
            self.assertEqual((await client.get(path, params={'session_id': sid})).json()['messages'], [])
            self.assertEqual(len((await client.get(path + '/sessions')).json()['sessions']), 2)

            backend.authorized(f'Bearer {token}')
            extracted = {'items': [dict(source_id=mid, quote=source, kind='story', title='求学',
                                        content='我在青禾中学念书', tags=['青禾中学'])]}
            with patch.object(backend, 'llm', AsyncMock(return_value=json.dumps(extracted))):
                self.assertEqual(await memory_worker.extract(pid), 'processed')
            turn = dict(request_id=uuid.uuid4().hex, session_id=sid, text='青禾中学是哪所学校？')
            with patch.object(backend, 'llm', AsyncMock(return_value='您提到曾在青禾中学念书。')) as model:
                reply = await client.post(path + '/turns', json=turn)
                self.assertEqual(reply.status_code, 200, reply.text)
                recent, memories = model.call_args.args[1].split('相关长期记忆', 1)
                self.assertNotIn(source, recent)
                self.assertIn(mid, memories)
                self.assertEqual((await client.post(path + '/turns', json=turn)).json(), reply.json())
                self.assertEqual((await client.post(path + '/turns', json={**turn, 'session_id': pid})).status_code, 409)
            history = (await client.get(path, params={'session_id': pid})).json()['messages']
            self.assertEqual([item['id'] for item in history], [mid])
            self.assertEqual((await client.get(f'/api/messages/{mid}/audio')).status_code, 200)
            self.assertEqual((await client.put(f'{path}/sessions/{pid}/active')).status_code, 200)
            self.assertEqual((await client.get(path + '/sessions')).json()['active_id'], pid)
            self.assertEqual((await client.patch(f'{path}/sessions/{sid}', json={'title': '上学的故事'})).status_code, 200)
            other = (await client.post('/api/people', json={'name': '另一位讲述者'})).json()['id']
            other_path = f'/api/people/{other}'
            self.assertEqual((await client.put(f'{other_path}/sessions/{sid}/active')).status_code, 404)
            book = (await client.get(other_path + '/memories')).json()
            self.assertEqual(book['items'][0]['source_id'], mid)
            await client.patch(other_path + '/memory-settings', json={'enabled': False})
            self.assertFalse((await client.get(path + '/memories')).json()['enabled'])
            foreign = (await client.post('/api/bootstrap')).json()['token']
            self.assertEqual((await client.get(path + '/sessions',
                                               headers={'Authorization': f'Bearer {foreign}'})).status_code, 404)
