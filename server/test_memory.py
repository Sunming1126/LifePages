import json
import unittest
import uuid
from contextlib import closing
from unittest.mock import AsyncMock, patch

from server.test_app import backend, httpx, wav
from server import memory, memory_worker
from server.memory_vectors import VectorIndex


class MemoryTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.client = httpx.AsyncClient(transport=httpx.ASGITransport(app=backend.app), base_url='http://test')
        self.token = (await self.client.post('/api/bootstrap')).json()['token']
        self.client.headers['Authorization'] = 'Bearer ' + self.token
        await self.client.put('/api/profile/background-ai', json={'enabled': True})
        self.pid = (await self.client.get('/api/current-person')).json()['id']
        self.path = f'/api/people/{self.pid}'
        backend.authorized('Bearer ' + self.token)

    async def asyncTearDown(self):
        await self.client.aclose()

    async def add(self, text, audio=False):
        r = await self.client.post(f'{self.path}/answers', json={'text': text, 'audio_base64': wav() if audio else None})
        self.assertEqual(r.status_code, 200)
        return r.json()['id']

    async def book(self):
        result = await self.client.get(f'{self.path}/memories')
        self.assertEqual(result.status_code, 200, result.text)
        return result.json()

    async def turn(self, text, request_id=None):
        result = await self.client.post(f'{self.path}/turns', json={
            'text': text, 'request_id': request_id or uuid.uuid4().hex,
        })
        self.assertEqual(result.status_code, 200, result.text)
        return result.json()

    async def test_legacy_backfill_retries_and_only_accepts_user_quotes(self):
        text = '我小时候常跟着爷爷去白沙码头修船。'
        mid = await self.add(text, audio=True)
        await self.add('今天还好吗？')
        with closing(backend.db()) as c, c:
            c.execute('INSERT INTO messages(id,person_id,role,text) VALUES(?,?,?,?)',
                      ('assistant', self.pid, 'assistant', '你曾经出过远海。'))
        self.assertTrue((await self.book())['enabled'])
        with patch.object(backend, 'llm', AsyncMock(return_value='没有返回 JSON')):
            self.assertEqual(await memory_worker.extract(self.pid), 'retry')
        self.assertEqual((await self.book())['processed'], 0)
        with closing(backend.db()) as c, c:
            c.execute('UPDATE memory_progress SET retry_at=0')

        async def model(_, context):
            self.assertEqual([r['text'] for r in json.loads(context)], ['今天还好吗？', text])
            return json.dumps({'items': [
                {'source_id': mid, 'quote': text, 'kind': 'story', 'title': '白沙码头',
                 'content': '儿时跟爷爷在白沙码头修船', 'tags': ['白沙码头']},
                {'source_id': 'assistant', 'quote': '你曾经出过远海。', 'kind': 'fact',
                 'title': '远海', 'content': '曾经出远海'},
                {'source_id': mid, 'quote': '我小时候经常出远海。', 'kind': 'fact',
                 'title': '远海', 'content': '曾经出远海'},
            ]})

        with patch.object(backend, 'llm', model):
            self.assertEqual(await memory_worker.extract(self.pid), 'processed')
            self.assertEqual(await memory_worker.extract(self.pid), 'idle')
        book = await self.book()
        self.assertEqual((book['total'], book['processed']), (2, 2))
        item, = book['items']
        self.assertEqual(item['audio_id'], mid)
        self.assertEqual(item['quote'], text)
        result = await self.client.get(f"{self.path}/memories/{item['id']}/source")
        self.assertEqual(result.json()['text'], text)
        self.assertEqual((await self.client.get(f'/api/messages/{mid}/audio')).status_code, 200)

    async def test_confirmed_graph_and_narrator_isolation(self):
        first, second = '我女儿是小芳。', '小芳的儿子叫小东。'
        a, b = await self.add(first), await self.add(second)
        relations = [
            dict(source_id=a, quote=first, kind='relation', subject='@self', predicate='女儿',
                 object='小芳', title='女儿', content='我的女儿是小芳'),
            dict(source_id=b, quote=second, kind='relation', subject='小芳', predicate='儿子',
                 object='小东', title='小芳的孩子', content='小芳的儿子叫小东'),
        ]
        with patch.object(backend, 'llm', AsyncMock(return_value=json.dumps({'items': relations}))):
            self.assertEqual(await memory_worker.extract(self.pid), 'processed')
        _, entries = await backend.recall(self.pid, '小东是我的孙辈吗')
        self.assertEqual(entries, [])
        items = (await self.book())['items']
        for item in items:
            result = await self.client.patch(f"{self.path}/memories/{item['id']}",
                                             json={'confirm': True, 'revision': item['revision']})
            self.assertEqual(result.status_code, 200, result.text)
        with patch.object(backend, 'llm', AsyncMock(return_value='小东是您的孙辈。')) as model:
            await self.turn('小东是我的孙辈吗')
        self.assertIn('小东是讲述者的孙辈（经过小芳）', model.call_args.args[1])
        self.assertIn(a, model.call_args.args[1])
        self.assertIn(b, model.call_args.args[1])

        other = (await self.client.post('/api/people', json={'name': '别人'})).json()['id']
        with patch.object(backend, 'llm', AsyncMock(return_value='能再说说他吗？')) as model:
            result = await self.client.post(f'/api/people/{other}/turns', json={
                'request_id': uuid.uuid4().hex, 'text': '小东是我的孙辈吗',
            })
        self.assertEqual(result.status_code, 200)
        self.assertNotIn('经过小芳', model.call_args.args[1])
        other_token = backend.bootstrap()['token']
        response = await self.client.get(f'{self.path}/memories', headers={'Authorization': f'Bearer {other_token}'})
        self.assertEqual(response.status_code, 404)

    async def test_edit_pause_and_delete_override_stale_index_and_pending_extraction(self):
        text = '我在白沙码头修船。'
        mid = await self.add(text)
        request_id = uuid.uuid4().hex
        with patch.object(backend, 'llm', AsyncMock(return_value='记下了。')) as model:
            first = await self.turn('记住这个', request_id)
            self.assertEqual(first, await self.turn('记住这个', request_id))
            self.assertEqual(model.await_count, 1)
            self.assertIn('已经保存', model.call_args.args[1])
        item, = (await self.book())['items']
        self.assertEqual(item['source_id'], mid)
        iid, revision = item['id'], item['revision']
        path = f'{self.path}/memories/{iid}'
        vector = VectorIndex()
        with closing(backend.db()) as c, c:
            c.execute('UPDATE memory_items SET indexed_revision=revision,index_key=? WHERE id=?', (vector.key, iid))
        with patch.dict('os.environ', {'LIFEPAGES_QDRANT_URL': 'http://qdrant.test'}), \
                patch.object(VectorIndex, 'search', AsyncMock(return_value={iid: (revision, .98)})) as search:
            with closing(backend.db()) as c, c:
                c.execute('UPDATE memory_items SET index_key=? WHERE id=?', (VectorIndex().key, iid))
            _, entries = await backend.recall(self.pid, '完全不同的问法')
            search.assert_awaited_once()
            self.assertEqual(entries[0]['id'], iid)
        duplicate = await self.add(text)
        epoch, rows = memory_worker.snapshot(self.pid)
        self.assertEqual([row['id'] for row in rows], [duplicate, mid])
        edited = await self.client.patch(path, json={'revision': revision, 'content': '我在白沙码头补渔网。'})
        self.assertEqual(edited.status_code, 200, edited.text)
        self.assertFalse(memory_worker.commit(self.pid, epoch, rows, []))
        self.assertEqual(memory_worker.snapshot(self.pid)[1], [])
        with closing(backend.db()) as c:
            self.assertEqual(memory.rank(c, self.pid, '完全不同的问法', {iid: (revision, .98)}), [])
            recalled = memory.rank(c, self.pid, '白沙码头', {})[0]
        self.assertIn('补渔网', recalled['记忆'])
        self.assertNotIn('原话', recalled)
        self.assertEqual((await self.client.patch(path, json={'revision': revision, 'title': '过期更正'})).status_code, 409)

        await self.add('后来我去做渔网了。')
        epoch, rows = memory_worker.snapshot(self.pid)
        result = await self.client.patch(f'{self.path}/memory-settings', json={'enabled': False})
        self.assertEqual(result.json(), {'enabled': False})
        self.assertFalse(memory_worker.commit(self.pid, epoch, rows, []))
        self.assertEqual(memory_worker.snapshot(self.pid)[1], [])
        self.assertEqual((await backend.recall(self.pid, '白沙码头'))[1], [])
        await self.client.patch(f'{self.path}/memory-settings', json={'enabled': True})
        self.assertEqual((await self.client.delete(path)).status_code, 200)
        self.assertEqual((await self.book())['items'], [])
        self.assertEqual((await backend.recall(self.pid, '白沙码头'))[1], [])
        self.assertEqual((await self.client.get(f'{path}/source')).status_code, 404)
        person = await self.client.get(self.path)
        self.assertIn(text, [m['text'] for m in person.json()['messages']])

    async def test_vector_protocol_is_scoped_and_uses_revision_only(self):
        with patch.dict('os.environ', {'LIFEPAGES_QDRANT_URL': 'http://qdrant.test'}):
            index = VectorIndex()
        row = dict(id=str(uuid.uuid4()), title='往事', content='我在码头修船', tags='[]', revision=3, status='active')
        scope = index.scope('device-a', self.pid)
        stored = []
        paths = []

        def reply(request):
            paths.append((request.method, request.url.path))
            if request.url.path == '/embed':
                self.assertEqual(len(json.loads(request.content)['texts']), 1)
                return httpx.Response(200, json={'vectors': [[1.0] + [0.0] * 511]})
            if request.method == 'GET':
                return httpx.Response(404)
            if request.url.path.endswith('/points'):
                stored.extend(json.loads(request.content)['points'])
            if request.url.path.endswith('/points/query'):
                data = json.loads(request.content)
                self.assertEqual({x['key']: x['match']['value'] for x in data['filter']['must']}, scope)
                return httpx.Response(200, json={'result': {'points': [
                    dict(id=row['id'], payload=stored[0]['payload'], score=.84),
                    dict(id='other', payload={**scope, 'account': 'device-b', 'memory_id': 'other', 'revision': 3}, score=1.0),
                ]}})
            if request.url.path.endswith('/points/delete'):
                self.assertEqual(json.loads(request.content), {'points': [index.point_id('device-a', self.pid, row['id'])]})
            return httpx.Response(200)

        factory = httpx.AsyncClient
        with patch.object(httpx, 'AsyncClient', side_effect=lambda **kw: factory(transport=httpx.MockTransport(reply), **kw)):
            await index.sync('device-a', self.pid, [row])
            self.assertEqual(stored[0]['payload'], {**scope, 'memory_id': row['id'], 'revision': 3})
            self.assertEqual(await index.search('device-a', self.pid, '船是在哪儿修的？'), {row['id']: (3, .84)})
            await index.sync('device-a', self.pid, [{**row, 'status': 'deleted'}])
        self.assertIn(('POST', f'/collections/{index.collection}/points/delete'), paths)
