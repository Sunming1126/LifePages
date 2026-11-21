import base64
import json
import unittest
import uuid
from pathlib import Path
from unittest.mock import AsyncMock, patch

from server.test_app import backend, httpx


class ManuscriptTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.client = httpx.AsyncClient(transport=httpx.ASGITransport(app=backend.app), base_url='http://test')
        token = (await self.client.post('/api/bootstrap')).json()['token']
        self.client.headers['Authorization'] = f'Bearer {token}'
        backend.authorized(f'Bearer {token}')

    async def asyncTearDown(self):
        await self.client.aclose()

    async def open_topic(self, bid, index=0):
        topics = (await self.client.get(f'/api/books/{bid}/topics')).json()['topics']
        tid = topics[index]['id']
        result = await self.client.put(f'/api/books/{bid}/topics/{tid}/active')
        self.assertEqual(result.status_code, 200, result.text)
        return tid

    async def test_empty_interview_opens_full_blank_editor_and_saves_manual_text(self):
        bid = (await self.client.post('/api/books', json={'title': '虚构手写书', 'name': '测试', 'author': '测试',
            'interview': True, 'interview_version': 2})).json()['id']
        path = f'/api/books/{bid}/topics?editor=true&include_manuscript=true&interview_only=true'
        opened = await self.client.get(path)
        self.assertEqual(opened.status_code, 200, opened.text)
        value = opened.json()
        tid = value['active_id']
        self.assertEqual(value['manuscript']['blocks'], [])
        self.assertEqual((await self.client.get(path)).json()['active_id'], tid)
        self.assertEqual((await self.client.get(f'/api/books/{bid}/chapters')).json(), [])
        saved = await self.client.put(f'/api/books/{bid}/topics/{tid}/manuscript', json={
            'revision': 0, 'blocks': [{'id': uuid.uuid4().hex, 'kind': 'text', 'text': '这是我自己写下的虚构回忆。'}]})
        self.assertEqual(saved.status_code, 200, saved.text)
        restored = (await self.client.get(path)).json()['manuscript']
        self.assertEqual(restored['blocks'][0]['text'], '这是我自己写下的虚构回忆。')

    async def test_templates_and_idempotent_insertion(self):
        templates = (await self.client.get('/api/books/templates')).json()
        self.assertEqual([(row['id'], len(row['chapters'])) for row in templates],
                         [('life', 26), ('family', 8), ('turning_points', 8)])
        bid = (await self.client.get('/api/books')).json()['active_id']
        active = await self.open_topic(bid, 1)
        path = f'/api/books/{bid}/topics'
        original = (await self.client.get(path)).json()['topics']
        payload = {'id': uuid.uuid4().hex, 'after_id': original[0]['id'], 'title': '河边的新家'}
        for _ in range(2):
            inserted = await self.client.post(path, json=payload)
            self.assertEqual(inserted.json(), {'id': payload['id']})
        state = (await self.client.get(path)).json()
        self.assertEqual(state['active_id'], active)
        self.assertEqual([row['number'] for row in state['topics']], list(range(1, 28)))
        self.assertEqual([row['id'] for row in state['topics']],
                         [original[0]['id'], payload['id'], *[row['id'] for row in original[1:]]])
        self.assertEqual((await self.client.post(path, json={**payload, 'title': '重复请求'})).status_code, 409)

        for template in templates[1:]:
            result = await self.client.post('/api/books', json={
                'title': '测试模板', 'name': '讲述者', 'author': '作者',
                'template_id': template['id'],
            })
            self.assertEqual(result.status_code, 200, result.text)
            created = result.json()['id']
            topics = (await self.client.get(f'/api/books/{created}/topics')).json()['topics']
            self.assertEqual([row['title'] for row in topics], template['chapters'])
            self.assertTrue(all(row['question'] for row in topics))

    async def test_editor_initial_snapshot_and_generated_question(self):
        bid = (await self.client.get('/api/books')).json()['active_id']
        first = await self.open_topic(bid)
        other = await self.open_topic(bid, 1)
        path = f'/api/books/{bid}/topics'
        params = {'editor': 'true', 'include_manuscript': 'true'}
        initial = (await self.client.get(path, params=params)).json()
        self.assertEqual(initial['manuscript']['id'], other)
        selected = (await self.client.get(path, params={**params, 'preferred_id': first})).json()
        self.assertEqual(selected['active_id'], other)
        self.assertEqual(selected['manuscript'],
                         (await self.client.get(f'{path}/{first}/manuscript')).json())

        request = {'id': uuid.uuid4().hex, 'after_id': first, 'title': '院子里的枣树',
                   'generate_question': True, 'question': ' '}
        question = '您还记得和那棵枣树有关的哪件小事？'
        with patch.object(backend, 'llm', AsyncMock(side_effect=['无法生成。', question])) as model:
            failed = await self.client.post(path, json=request)
            self.assertEqual(failed.status_code, 502)
            self.assertEqual((await self.client.get(path, params=params)).json(), initial)
            created = await self.client.post(path, json=request)
            self.assertEqual(created.status_code, 200)
            self.assertEqual((await self.client.post(path, json=request)).json(), created.json())
            self.assertEqual(model.await_count, 2)
            context = json.loads(model.call_args.args[1])
            self.assertEqual(context['新章节标题'], request['title'])
            self.assertIn('故乡的轮廓', context['现有章节标题'])
            manual = await self.client.post(path, json={
                **request, 'id': uuid.uuid4().hex, 'title': '自填问题',
                'question': '您最想从哪里讲起？',
            })
            self.assertEqual(manual.status_code, 200)
            self.assertEqual(model.await_count, 2)
        tid = created.json()['id']
        saved = (await self.client.get(f'{path}/{tid}/manuscript')).json()
        self.assertEqual(saved['question'], question)
        renamed = await self.client.patch(f'{path}/{tid}', json={
            'title': '枣树下的日子', 'question': '不应改写已有问题？', 'revision': saved['revision'],
        })
        self.assertEqual(renamed.json()['title'], '枣树下的日子')
        self.assertEqual(renamed.json()['question'], question)

    async def test_manuscript_projection_images_revision_and_ai(self):
        bid = (await self.client.get('/api/books')).json()['active_id']
        tid = await self.open_topic(bid)
        other = await self.open_topic(bid, 1)
        path = f'/api/books/{bid}/topics/{tid}'
        content = f'{path}/manuscript'
        empty = (await self.client.get(content)).json()
        self.assertEqual(empty['blocks'], [])
        with patch.object(backend, 'llm', AsyncMock(return_value='您慢慢说。')):
            narration = await self.client.post(f'/api/people/{bid}/turns', json={
                'request_id': uuid.uuid4().hex, 'session_id': tid, 'text': '我曾经住在河边。',
            })
        source = narration.json()['user_id']
        with patch.object(backend, 'llm', AsyncMock(return_value=json.dumps({
            'body': '旧版整理的正文。', 'source_ids': [1],
        }))):
            self.assertEqual((await self.client.post(f'{path}/compile')).status_code, 200)
        current = (await self.client.get(content)).json()
        first, = current['blocks']
        self.assertEqual(first['text'], '旧版整理的正文。')
        photo_id = uuid.uuid4().hex
        image = base64.b64encode(Path('assets/memoir-cover.jpg').read_bytes()).decode('ascii')
        upload = {'id': photo_id, 'data': image}
        self.assertEqual((await self.client.put(f'{path}/images', json=upload)).status_code, 200)
        self.assertEqual((await self.client.put(f'{path}/images', json=upload)).status_code, 200)
        self.assertEqual((await self.client.get(f'{path}/images/{photo_id}')).json()['data'], image)
        self.assertEqual((await self.client.get(f'/api/books/{bid}/topics/{other}/images/{photo_id}')).status_code, 404)
        second_token = (await self.client.post('/api/bootstrap')).json()['token']
        self.assertEqual((await self.client.get(f'{path}/images/{photo_id}',
            headers={'Authorization': f'Bearer {second_token}'})).status_code, 404)
        blocks = [
            {**first, 'text': '手工改过的第一段。'},
            {'id': photo_id, 'kind': 'image', 'image_id': photo_id},
            {'id': uuid.uuid4().hex, 'kind': 'text', 'text': '第二段。'},
        ]
        payload = {'revision': current['revision'], 'blocks': blocks}
        result = await self.client.put(content, json=payload)
        self.assertEqual(result.status_code, 200, result.text)
        saved = result.json()
        self.assertEqual(saved['revision'], current['revision'] + 1)
        self.assertEqual((await self.client.put(content, json=payload)).json(), saved)
        self.assertEqual((await self.client.put(content, json={**payload, 'blocks': []})).status_code, 409)
        preview, = (await self.client.get(f'/api/books/{bid}/chapters?include_material=true')).json()
        self.assertEqual(preview['blocks'], blocks)
        self.assertEqual(preview['content'], '手工改过的第一段。\n\n第二段。')

        with patch.object(backend, 'llm', AsyncMock(return_value='AI 修改的第二段。')) as llm:
            suggestion = await self.client.post(f'{path}/suggest', json={
                'revision': saved['revision'], 'block_id': blocks[-1]['id'], 'instruction': '改得口语一点',
            })
            self.assertEqual(suggestion.json()['text'], 'AI 修改的第二段。')
            self.assertEqual(json.loads(llm.call_args.args[1])['要编辑的段落'], '第二段。')
        self.assertEqual((await self.client.get(content)).json()['blocks'], blocks)
        with patch.object(backend, 'llm', AsyncMock(return_value='您继续说。')):
            new = await self.client.post(f'/api/people/{bid}/turns', json={
                'request_id': uuid.uuid4().hex, 'session_id': tid, 'text': '后来我们搬到了城里。',
            })
        with patch.object(backend, 'llm', AsyncMock(return_value=json.dumps({
            'body': '后来我们搬到了城里。', 'source_ids': [1],
        }))) as llm:
            self.assertEqual((await self.client.post(f'{path}/draft')).json()['outcome'], 'created')
            self.assertIn('可追加的新段落', llm.call_args.args[0])
        draft = (await self.client.get(f'{path}/draft')).json()['draft']
        self.assertEqual((await self.client.put(f"{path}/draft/{draft['id']}")).status_code, 200)
        revised = (await self.client.get(content)).json()['blocks']
        self.assertEqual(revised[:3], blocks)
        self.assertEqual(revised[-1]['text'], '后来我们搬到了城里。')

    async def test_next_stream_reads_complete_previous_reply_in_same_chapter(self):
        bid = (await self.client.get('/api/books')).json()['active_id']
        tid = await self.open_topic(bid)
        path = f'/api/people/{bid}/turns/stream'
        contexts = []

        async def model(_, context):
            contexts.append(context)
            yield '那条河就在村口，' if len(contexts) == 1 else '我明白了。'
            if len(contexts) == 1:
                yield '您还记得河边的桥吗？'

        with patch.object(backend, 'stream_llm', model):
            for text in ('小时候村口有一条河。', '桥是木头搭的。'):
                reply = await self.client.post(path, json={
                    'session_id': tid, 'request_id': uuid.uuid4().hex, 'text': text, 'speak': True,
                })
                self.assertEqual(json.loads(reply.text.splitlines()[-1])['type'], 'done')
        self.assertIn('讲述者：小时候村口有一条河。', contexts[1])
        self.assertIn('助手：那条河就在村口，您还记得河边的桥吗？', contexts[1])
        self.assertIn('讲述者：桥是木头搭的。', contexts[1])
