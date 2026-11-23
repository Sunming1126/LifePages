import asyncio
import json
import time
import unittest
import uuid
from contextlib import closing
from unittest.mock import AsyncMock, patch
from server.test_app import backend, httpx, wav
from server import chat_sessions


class ModeTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.client = httpx.AsyncClient(transport=httpx.ASGITransport(app=backend.app), base_url='http://test')
        self.token = (await self.client.post('/api/bootstrap')).json()['token']
        self.client.headers['Authorization'] = 'Bearer ' + self.token

    async def asyncTearDown(self):
        await self.client.aclose()

    async def create(self, mode):
        response = await self.client.post('/api/books', json={'id': uuid.uuid4().hex,
            'title': '虚构双模式测试', 'name': '测试', 'author': '测试', 'book_mode': mode})
        self.assertEqual(response.status_code, 200, response.text)
        return response.json()['id']

    async def test_modes_are_pinned_and_directory_and_companion_use_separate_entries(self):
        bid = await self.create('directory')
        shelf = (await self.client.get('/api/books')).json()
        row = next(b for b in shelf['books'] if b['id'] == bid)
        self.assertEqual(row['book_mode'], 'directory')
        self.assertIsNone(row['interview_version'])
        self.assertEqual(len((await self.client.get(f'/api/books/{bid}/topics')).json()['topics']), 26)
        self.assertEqual((await self.client.post(f'/api/books/{bid}/interview')).status_code, 409)
        changed = await self.client.post('/api/books', json={'id': bid, 'title': row['title'], 'name': row['name'],
            'author': row['author'], 'book_mode': 'companion'})
        self.assertEqual(changed.status_code, 409)
        companion = await self.create('companion')
        self.assertEqual((await self.client.post(f'/api/books/{companion}/interview')).json()['interview']['version'], 2)
        self.assertEqual((await self.client.get(f'/api/books/{companion}/directory')).status_code, 409)

    async def test_directory_edit_order_archive_restore_preserves_text_and_recording(self):
        bid = await self.create('directory')
        path = f'/api/books/{bid}/directory'
        value = (await self.client.get(path)).json()
        tid = value['topics'][0]['id']
        await self.client.put(f'/api/books/{bid}/topics/{tid}/active')
        payload = {'session_id': tid, 'request_id': uuid.uuid4().hex, 'text': '虚构：爷爷在石桥边等我放学。', 'audio_base64': wav()}
        with patch.object(backend, 'llm', AsyncMock(return_value='那天您和爷爷一起做了什么？')):
            answered = await self.client.post(f'/api/people/{bid}/turns', json=payload)
        self.assertEqual(answered.status_code, 200, answered.text)
        original = answered.json()['user_id']
        manuscript = (await self.client.get(f'/api/books/{bid}/topics/{tid}/manuscript')).json()
        saved = await self.client.put(f'/api/books/{bid}/topics/{tid}/manuscript', json={'revision': manuscript['revision'],
            'blocks': [{'id': uuid.uuid4().hex, 'kind': 'text', 'text': '虚构原稿，保留。'}]})
        self.assertEqual(saved.status_code, 200)
        edited = await self.client.patch(f'{path}/items/{tid}', json={'revision': value['revision'], 'title': '石桥', 'question': '哪次在石桥边等人的经历让您印象深？'})
        self.assertEqual(edited.status_code, 200, edited.text)
        value = edited.json()
        ids = [r['id'] for r in reversed(value['topics'])]
        value = (await self.client.put(path + '/order', json={'revision': value['revision'], 'ids': ids})).json()
        self.assertEqual([r['id'] for r in value['topics']], ids)
        archived = await self.client.post(f'{path}/items/{tid}/archive', json={'revision': value['revision']})
        self.assertEqual(archived.status_code, 200, archived.text)
        self.assertEqual((await self.client.get(f'/api/books/{bid}/chapters')).json(), [])
        self.assertEqual((await self.client.put(f'/api/books/{bid}/topics/{tid}/active')).status_code, 410)
        self.assertEqual((await self.client.get(f'/api/messages/{original}/audio')).status_code, 200)
        restored = await self.client.post(f'{path}/items/{tid}/restore', json={'revision': archived.json()['revision']})
        self.assertEqual(restored.status_code, 200, restored.text)
        chapters = (await self.client.get(f'/api/books/{bid}/chapters')).json()
        self.assertEqual(chapters[0]['content'], '虚构原稿，保留。')
        self.assertEqual(chapters[0]['title'], '石桥')

    async def test_duplicate_add_stale_sort_and_cross_book_ids_do_not_change_directory(self):
        bid, other = await self.create('directory'), await self.create('directory')
        path = f'/api/books/{bid}/directory'
        first = (await self.client.get(path)).json()
        new = {'revision': first['revision'], 'id': uuid.uuid4().hex, 'title': '一门本领', 'question': '您是怎么学会这门本领的？'}
        added = await self.client.post(path + '/items', json=new)
        retry = await self.client.post(path + '/items', json=new)
        self.assertEqual(added.json(), retry.json())
        self.assertEqual(len(added.json()['topics']), 27)
        stale = await self.client.put(path + '/order', json={'revision': first['revision'], 'ids': [r['id'] for r in first['topics']]})
        self.assertEqual(stale.status_code, 409)
        foreign = (await self.client.get(f'/api/books/{other}/directory')).json()['topics'][0]['id']
        denied = await self.client.post(f'{path}/items/{foreign}/archive', json={'revision': added.json()['revision']})
        self.assertEqual(denied.status_code, 404)
        self.assertEqual((await self.client.get(path)).json(), added.json())

    async def test_empty_directory_can_add_and_restore_without_erasing_old_topics(self):
        bid = await self.create('directory')
        path = f'/api/books/{bid}/directory'
        value = (await self.client.get(path)).json()
        original = [r['id'] for r in value['topics']]
        for tid in original:
            response = await self.client.post(f'{path}/items/{tid}/archive', json={'revision': value['revision']})
            self.assertEqual(response.status_code, 200, response.text)
            value = response.json()
        opened = (await self.client.get(f'/api/books/{bid}/topics')).json()
        self.assertIsNone(opened['active_id'])
        self.assertEqual(opened['topics'], [])
        value = (await self.client.post(path + '/items', json={'revision': value['revision'], 'id': uuid.uuid4().hex,
            'title': '重新开始', 'question': '您想先记录哪件事？'})).json()
        self.assertEqual(value['topics'][0]['number'], 1)
        restored = (await self.client.post(f'{path}/items/{original[0]}/restore', json={'revision': value['revision']})).json()
        self.assertEqual([r['number'] for r in restored['topics']], [1, 2])

    async def test_directory_revision_tracks_regular_editor_metadata_changes(self):
        bid = await self.create('directory')
        path = f'/api/books/{bid}/directory'
        value = (await self.client.get(path)).json()
        tid = value['topics'][0]['id']
        row = (await self.client.get(f'/api/books/{bid}/topics/{tid}/manuscript')).json()
        renamed = await self.client.patch(f'/api/books/{bid}/topics/{tid}', json={
            'revision': row['revision'], 'title': '另一台设备的新目录名'})
        self.assertEqual(renamed.status_code, 200, renamed.text)
        stale = await self.client.patch(f'{path}/items/{tid}', json={
            'revision': value['revision'], 'title': '过时名称', 'question': '过时的问题？'})
        self.assertEqual(stale.status_code, 409)
        self.assertEqual((await self.client.get(path)).json()['topics'][0]['title'], '另一台设备的新目录名')

    async def test_other_account_cannot_manage_or_greet_this_book(self):
        bid = await self.create('directory')
        companion, mid = await self.setup_return()
        other_token = (await self.client.post('/api/bootstrap')).json()['token']
        self.client.headers['Authorization'] = 'Bearer ' + other_token
        self.assertEqual((await self.client.get(f'/api/books/{bid}/directory')).status_code, 404)
        denied = await self.client.post(f'/api/books/{companion}/interview/resume', json={
            'left_at': int(time.time()) - 3600, 'last_user_id': mid, 'request_id': uuid.uuid4().hex})
        self.assertEqual(denied.status_code, 404)

    async def setup_return(self):
        bid = await self.create('companion')
        state = (await self.client.post(f'/api/books/{bid}/interview')).json()
        backend.authorized('Bearer ' + self.token)
        mid = uuid.uuid4().hex
        with closing(backend.db()) as c, c:
            c.execute('INSERT INTO messages(id,person_id,role,text) VALUES(?,?,?,?)', (mid, bid, 'user', '虚构：小时候我常去河边看人捕鱼。'))
            chat_sessions.bind(c, bid, state['active_id'], mid)
        return bid, mid

    async def test_hour_return_once_and_no_progress_or_material_is_consumed(self):
        bid, mid = await self.setup_return()
        before = (await self.client.post(f'/api/books/{bid}/interview')).json()['interview']
        left = int(time.time()) + 1
        payload = {'left_at': left, 'last_user_id': mid, 'request_id': uuid.uuid4().hex}
        with patch('server.companion_resume.time.time', return_value=left + 3600):
            first = await self.client.post(f'/api/books/{bid}/interview/resume', json=payload)
            retry = await self.client.post(f'/api/books/{bid}/interview/resume', json=payload)
            duplicate = await self.client.post(f'/api/books/{bid}/interview/resume', json={**payload, 'request_id': uuid.uuid4().hex})
        self.assertEqual(first.status_code, 200, first.text)
        self.assertIsNotNone(first.json()['message_id'])
        self.assertEqual(first.json(), retry.json())
        self.assertIsNone(duplicate.json()['message_id'])
        self.assertEqual(first.json()['interview']['characters'], before['characters'])
        self.assertEqual(first.json()['interview']['question'], before['question'])
        self.assertEqual(first.json()['interview']['revision'], before['revision'])

    async def test_welcome_choices_continue_without_word_padding_or_open_next_topic(self):
        bid = await self.create('companion')
        path = f'/api/books/{bid}/interview'
        opened = (await self.client.post(path)).json()
        sid = opened['active_id']
        await self.client.post(f'/api/people/{bid}/turns', json={'request_id': uuid.uuid4().hex,
            'session_id': sid, 'text': '开始访谈', 'interview_action': 'begin', 'interview_revision': opened['interview']['revision']})
        with patch.object(backend, 'llm', AsyncMock()) as model:
            moved = await self.client.post(f'/api/people/{bid}/turns', json={'request_id': uuid.uuid4().hex,
                'session_id': sid, 'text': '开始一个新的话题'})
        self.assertEqual(moved.status_code, 200, moved.text)
        self.assertEqual(moved.json()['interview']['question'], 2)
        model.assert_not_called()
        with patch.object(backend, 'llm', AsyncMock(return_value=json.dumps({'questions': ['小时候家里忙起来时，您会帮着做什么？']}))) as model:
            continued = await self.client.post(f'/api/people/{bid}/turns', json={'request_id': uuid.uuid4().hex,
                'session_id': sid, 'text': '继续刚才的聊天'})
        self.assertEqual(continued.status_code, 200, continued.text)
        self.assertEqual(continued.json()['interview']['question'], 2)
        self.assertEqual(continued.json()['interview']['characters'], 0)
        self.assertFalse(model.call_args.kwargs['thinking'])

    async def test_short_absence_or_new_user_message_prevents_return_prompt(self):
        bid, mid = await self.setup_return()
        left = int(time.time()) + 1
        path = f'/api/books/{bid}/interview/resume'
        with patch('server.companion_resume.time.time', return_value=left + 3599):
            short = await self.client.post(path, json={'left_at': left, 'last_user_id': mid, 'request_id': uuid.uuid4().hex})
        self.assertIsNone(short.json()['message_id'])
        with patch('server.companion_resume.time.time', return_value=left + 3601):
            stale = await self.client.post(path, json={'left_at': left, 'last_user_id': 'newer-or-different-message', 'request_id': uuid.uuid4().hex})
        self.assertIsNone(stale.json()['message_id'])
