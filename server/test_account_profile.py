import base64
import json
import unittest
import uuid
from pathlib import Path
from unittest.mock import AsyncMock, patch

from server.test_app import backend, httpx
from server import account_profile, memory_worker


class ProfileTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.client = httpx.AsyncClient(transport=httpx.ASGITransport(app=backend.app), base_url='http://test')
        self.headers = await self.guest()

    async def asyncTearDown(self):
        await self.client.aclose()

    async def guest(self):
        token = (await self.client.post('/api/bootstrap')).json()['token']
        return {'Authorization': f'Bearer {token}'}

    async def read(self, headers=None):
        response = await self.client.get('/api/profile', headers=headers or self.headers)
        self.assertEqual(response.status_code, 200, response.text)
        return response.json()

    async def test_background_ai_requires_explicit_account_permission(self):
        path = '/api/profile/background-ai'
        self.assertEqual((await self.client.get(path)).status_code, 401)
        self.assertEqual((await self.client.get(path, headers=self.headers)).json(), {'enabled': False})
        other = await self.guest()
        pid = (await self.client.get('/api/current-person', headers=self.headers)).json()['id']
        await self.client.post(f'/api/people/{pid}/answers', headers=self.headers,
                               json={'text': '这段讲述只在获得授权后用于后台处理。'})
        backend.authorized(self.headers['Authorization'])
        with patch.object(backend, 'llm', AsyncMock(return_value='{"items":[]}')) as model:
            self.assertEqual(await memory_worker.extract(pid), 'idle')
            model.assert_not_awaited()
            self.assertEqual((await self.client.put(path, headers=self.headers,
                                                    json={'enabled': True})).json(), {'enabled': True})
            self.assertEqual((await self.client.get(path, headers=other)).json(), {'enabled': False})
            self.assertEqual(await memory_worker.extract(pid), 'processed')
            model.assert_awaited_once()
            await self.client.put(path, headers=self.headers, json={'enabled': False})
            self.assertEqual(await memory_worker.extract(pid), 'idle')
            model.assert_awaited_once()

    async def test_store_pages_are_public_and_link_to_apple_terms(self):
        for path, phrase in (('privacy', '阿里云百炼'), ('permissions', '麦克风'),
                             ('support', 'mailto:')):
            page = await self.client.get('/' + path)
            self.assertEqual(page.status_code, 200)
            self.assertIn(phrase, page.text)
            self.assertIn('https://www.apple.com/legal/internet-services/itunes/dev/stdeula/', page.text)

    async def test_account_profile_is_private_and_partial_updates_keep_avatar(self):
        self.assertEqual((await self.client.get('/api/profile')).status_code, 401)
        avatar = base64.b64encode(Path('assets/memoir-cover.jpg').read_bytes()).decode()
        result = await self.client.patch('/api/profile', headers=self.headers,
                                         json={'display_name': '  小林  ', 'avatar': avatar})
        self.assertEqual(result.status_code, 200, result.text)
        self.assertEqual(result.json()['display_name'], '小林')
        self.assertEqual(result.json()['avatar'], avatar)
        self.assertEqual((await self.read(await self.guest()))['display_name'], '')
        await self.client.patch('/api/profile', headers=self.headers, json={'display_name': '小周'})
        self.assertEqual((await self.read())['avatar'], avatar)
        await self.client.patch('/api/profile', headers=self.headers, json={'avatar': None})
        self.assertIsNone((await self.read())['avatar'])

    async def test_three_successful_ai_questions_and_reset_at_beijing_day_boundary(self):
        async def call(method, path, body=None):
            return await self.client.request(method, path, headers=self.headers, json=body)

        bid = (await call('GET', '/api/books')).json()['active_id']
        topics = f'/api/books/{bid}/topics'
        tid = (await call('GET', topics)).json()['active_id']
        await call('PUT', f'{topics}/{tid}/active')
        history = (await call('GET', f'/api/people/{bid}?session_id={tid}')).json()['messages']
        opening, = history
        path = f'{topics}/{tid}/messages'
        with patch.object(account_profile, 'day_key', return_value='2026-11-12') as date:
            self.assertEqual((await call('POST', f"{path}/{opening['id']}/refresh",
                                         {'text': opening['text']})).status_code, 200)
            self.assertEqual((await self.read())['follow_ups']['remaining'], 3)
            initial = '您第一次走过那座桥是什么时候？'
            with patch.object(backend, 'llm', AsyncMock(return_value=initial)):
                turn = await call('POST', f'/api/people/{bid}/turns', {
                    'request_id': uuid.uuid4().hex, 'session_id': tid, 'text': '我从小住在桥边。',
                })
            route = f"{path}/{turn.json()['assistant_id']}/refresh"
            with patch.object(backend, 'llm', AsyncMock(return_value='无法生成')):
                self.assertEqual((await call('POST', route, {'text': initial})).status_code, 502)
            self.assertEqual((await self.read())['follow_ups']['remaining'], 3)
            text = initial
            for index, (prior, angle, replacement) in enumerate([
                ('经过', '人物', '那天是谁陪您走过那座桥的？'),
                ('人物', '感受', '站在桥上时您的心情是怎样的？'),
                ('感受', '变化', '后来那座桥有什么变化？'),
            ], 1):
                with patch.object(backend, 'llm', AsyncMock(return_value=json.dumps({
                    'previous_angle': prior, 'angle': angle, 'question': replacement,
                }))) as model:
                    response = await call('POST', route, {'text': text})
                    self.assertEqual(response.status_code, 200, response.text)
                    self.assertEqual(response.json()['text'], replacement)
                    self.assertEqual((await call('POST', route, {'text': text})).json(), response.json())
                    model.assert_awaited_once()
                self.assertEqual((await self.read())['follow_ups']['remaining'], 3 - index)
                text = replacement
            with patch.object(backend, 'llm', AsyncMock()) as model:
                self.assertEqual((await call('POST', route, {'text': text})).status_code, 429)
                model.assert_not_awaited()
            self.assertEqual((await self.read(await self.guest()))['follow_ups']['remaining'], 3)
            date.return_value = '2026-11-13'
            self.assertEqual((await self.read())['follow_ups']['remaining'], 3)
            with patch.object(backend, 'llm', AsyncMock(return_value=json.dumps({
                'previous_angle': '变化', 'angle': '影响', 'question': '那座桥怎样影响了您的生活？',
            }))):
                self.assertEqual((await call('POST', route, {'text': text})).status_code, 200)
            self.assertEqual((await self.read())['follow_ups']['remaining'], 2)
