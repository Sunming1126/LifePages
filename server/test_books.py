import base64
import json
import os
import time
import unittest
import uuid
from contextlib import closing
from pathlib import Path
from unittest.mock import AsyncMock, patch

from server.test_app import backend, httpx, wav
from server import book_api, book_store, memory_worker, scheduler


class BookTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.client = httpx.AsyncClient(transport=httpx.ASGITransport(app=backend.app), base_url='http://test')
        self.token = (await self.client.post('/api/bootstrap')).json()['token']
        self.client.headers['Authorization'] = f'Bearer {self.token}'
        await self.client.put('/api/profile/background-ai', json={'enabled': True})
        backend.authorized(f'Bearer {self.token}')

    async def asyncTearDown(self):
        await self.client.aclose()

    async def open_topic(self, bid, index=0):
        topics = (await self.client.get(f'/api/books/{bid}/topics')).json()['topics']
        self.assertEqual(len(topics), 26)
        tid = topics[index]['id']
        response = await self.client.put(f'/api/books/{bid}/topics/{tid}/active')
        self.assertEqual(response.status_code, 200, response.text)
        return tid

    async def test_opening_refresh_cycles_without_model_and_rejects_other_chapters(self):
        bid = (await self.client.get('/api/books')).json()['active_id']
        tid = await self.open_topic(bid)
        other = await self.open_topic(bid, 1)
        history = f'/api/people/{bid}?session_id={tid}'
        first, = (await self.client.get(history)).json()['messages']
        route = f"/api/books/{bid}/topics/{tid}/messages/{first['id']}/refresh"
        seen = [first['text']]
        with patch.object(backend, 'llm', AsyncMock()) as model:
            for _ in range(4):
                payload = {'text': seen[-1]}
                response = await self.client.post(route, json=payload)
                self.assertEqual(response.status_code, 200, response.text)
                self.assertEqual((await self.client.post(route, json=payload)).json(), response.json())
                seen.append(response.json()['text'])
            model.assert_not_called()
        self.assertEqual(len(set(seen[:4])), 4)
        self.assertEqual(seen[-1], seen[0])
        self.assertEqual((await self.client.get(history)).json()['messages'], [first])
        foreign = route.replace(f'/topics/{tid}/', f'/topics/{other}/')
        self.assertEqual((await self.client.post(foreign, json={'text': seen[0]})).status_code, 404)

    async def test_generated_refresh_changes_angle_and_keeps_message_identity(self):
        bid = (await self.client.get('/api/books')).json()['active_id']
        tid = await self.open_topic(bid)
        with patch.object(backend, 'llm', AsyncMock(return_value='那时您是什么感受？')):
            turn = (await self.client.post(f'/api/people/{bid}/turns', json={
                'session_id': tid, 'request_id': uuid.uuid4().hex, 'text': '老家的院子里有一棵枣树。',
            })).json()
        route = f"/api/books/{bid}/topics/{tid}/messages/{turn['assistant_id']}/refresh"
        alternative = '平时还有谁会在枣树下坐一坐？'
        with patch.object(backend, 'llm', AsyncMock(return_value=json.dumps({
            'previous_angle': '感受', 'angle': '人物', 'question': alternative,
        }))) as model:
            response = await self.client.post(route, json={'text': turn['text']})
            self.assertEqual(response.json(), {'id': turn['assistant_id'], 'text': alternative})
            self.assertIn('老家的院子里有一棵枣树。', model.call_args.args[1])
        with patch.object(backend, 'llm', AsyncMock(return_value=json.dumps({
            'previous_angle': '感受', 'angle': '人物', 'question': '还有谁会去院子里？',
        }))):
            response = await self.client.post(route, json={'text': alternative})
            self.assertEqual(response.status_code, 502)
        history = (await self.client.get(f'/api/people/{bid}?session_id={tid}')).json()['messages']
        self.assertEqual(len(history), 3)
        self.assertEqual(history[-1]['text'], alternative)
        self.assertEqual(history[-1]['id'], turn['assistant_id'])

    async def test_book_compilation_keeps_narrations_and_scopes_export_recordings(self):
        bid = (await self.client.get('/api/books')).json()['active_id']
        tid = await self.open_topic(bid)
        unrelated = await self.open_topic(bid, 1)
        await self.open_topic(bid, 2)  # Opening question alone does not enter the preview.
        chapters = f'/api/books/{bid}/chapters'

        async def tell(topic, text, reply='我在听。'):
            with patch.object(backend, 'llm', AsyncMock(return_value=reply)):
                result = await self.client.post(f'/api/people/{bid}/turns', json={
                    'session_id': topic, 'text': text, 'audio_base64': wav(),
                    'request_id': uuid.uuid4().hex,
                })
            self.assertEqual(result.status_code, 200, result.text)
            return result.json()['user_id']

        original, = (await self.client.get(f'/api/people/{bid}', params={'session_id': tid})).json()['messages']
        first = await tell(tid, '故乡在河边。', '那条河真让人怀念。您还记得河边的桥吗？')
        second = await tell(tid, '我记得当时的水声。')
        other = await tell(unrelated, '长辈住在邻村。')
        self.assertEqual((await self.client.get(chapters)).json(), [])
        preview = (await self.client.get(chapters, params={'include_material': 'true'})).json()
        self.assertEqual([row['topic_id'] for row in preview], [tid, unrelated])
        self.assertEqual([row['id'] for row in preview[0]['narrations']], [first, second])
        self.assertEqual(preview[0]['content'], '')

        compile_path = f'/api/books/{bid}/topics/{tid}/compile'
        with patch.object(backend, 'llm', AsyncMock(return_value=json.dumps({
            'body': '我的故乡在河边。', 'source_ids': [first],
        }))) as model:
            result = await self.client.post(compile_path)
            self.assertEqual(result.status_code, 200, result.text)
            cid = result.json()['id']
            self.assertEqual((await self.client.post(compile_path)).json()['id'], cid)
            model.assert_awaited_once()
        saved = (await self.client.get(chapters)).json()
        self.assertEqual(saved[0]['content'], '我的故乡在河边。')
        old = (await self.client.post(f'/api/chapters/{cid}/share')).json()['url'].rsplit('/', 1)[-1]
        qr = (await self.client.post(f'/api/chapters/{cid}/share', params={'include_topic_audio': 'true'})).json()
        self.assertEqual(qr['audio_count'], 2)
        token = qr['url'].rsplit('/', 1)[-1]
        later = await tell(tid, '后来我离开了故乡。')
        with closing(backend.db()) as c, c:
            c.execute('DELETE FROM recording_questions WHERE message_id=?', (first,))
        self.assertIn(original['text'].split('。')[-1], (await self.client.get(f'/listen/{old}')).text)
        refresh = await self.client.post(f"/api/books/{bid}/topics/{tid}/messages/{original['id']}/refresh",
                                         json={'text': original['text']})
        self.assertEqual(refresh.status_code, 200)
        opening = original['text'].split('。')[-1]
        self.assertIn(opening, (await self.client.get(f'/listen/{old}')).text)
        page = (await self.client.get(f'/listen/{token}')).text
        self.assertIn('我的故乡在河边。', page)
        self.assertIn(opening, page)
        self.assertNotIn(refresh.json()['text'], page)
        self.assertLess(page.index('您还记得河边的桥吗？'), page.index(f'/audio/{second}'))
        self.assertNotIn('那条河真让人怀念。', page)

        editor = f'/api/books/{bid}/topics/{tid}'
        draft = (await self.client.get(f'{editor}/manuscript')).json()
        photo, other_photo = uuid.uuid4().hex, uuid.uuid4().hex
        image = Path('assets/memoir-cover.jpg').read_bytes()
        for topic, iid in [(tid, photo), (unrelated, other_photo)]:
            upload = await self.client.put(f'/api/books/{bid}/topics/{topic}/images',
                                           json={'id': iid, 'data': base64.b64encode(image).decode('ascii')})
            self.assertEqual(upload.status_code, 200, upload.text)
        manuscript = await self.client.put(f'{editor}/manuscript', json={
            'revision': draft['revision'], 'blocks': [
                *draft['blocks'], {'id': photo, 'kind': 'image', 'image_id': photo},
                {'id': uuid.uuid4().hex, 'kind': 'text', 'text': '<b>手工编辑的第二段。</b>'},
            ],
        })
        self.assertEqual(manuscript.status_code, 200, manuscript.text)
        page = (await self.client.get(f'/listen/{token}')).text
        self.assertLess(page.index(f'/image/{photo}'), page.index('&lt;b&gt;手工编辑的第二段。&lt;/b&gt;'))
        response = await self.client.get(f'/listen/{token}/image/{photo}')
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.content, image)
        self.assertEqual((await self.client.get(f'/listen/{token}/image/{other_photo}')).status_code, 404)
        self.assertEqual((await self.client.get(f'/listen/{old}/audio/{second}')).status_code, 404)
        for mid in (first, second):
            self.assertEqual((await self.client.get(f'/listen/{token}/audio/{mid}')).status_code, 200)
        for mid in (other, later):
            self.assertEqual((await self.client.get(f'/listen/{token}/audio/{mid}')).status_code, 404)
        await self.client.delete(f'/api/books/{bid}')
        self.assertEqual((await self.client.get(f'/listen/{token}/audio/{first}')).status_code, 404)
        await self.client.post(f'/api/books/{bid}/restore')
        self.assertEqual((await self.client.get(f'/listen/{token}/audio/{first}')).status_code, 200)
        await self.client.delete(f'/api/chapters/{cid}/shares')
        self.assertEqual((await self.client.get(f'/listen/{token}')).status_code, 404)
        self.assertEqual((await self.client.get(f'/listen/{token}/image/{photo}')).status_code, 404)
        with patch.object(backend, 'llm', AsyncMock(return_value='{"body":"","source_ids":[]}')):
            result = await self.client.post(f'/api/books/{bid}/topics/{unrelated}/compile')
            self.assertEqual(result.status_code, 200, result.text)
        compiled = (await self.client.get(chapters)).json()
        self.assertEqual(compiled[1]['content'], '讲述原文\n\n长辈住在邻村。')

    async def test_scope_opening_and_review(self):
        shelf = (await self.client.get('/api/books')).json()
        book, = shelf['books']
        self.assertEqual((book['title'], book['name'], book['author']), ('我的回忆录', '您', '我'))
        bid = book['id']
        tid = await self.open_topic(bid)
        self.assertEqual(await self.open_topic(bid), tid)
        path = f'/api/people/{bid}'
        self.assertEqual(len((await self.client.get(path, params={'session_id': tid})).json()['messages']), 1)
        other_topic = await self.open_topic(bid, 1)
        with patch.object(backend, 'llm', AsyncMock(return_value='您能再讲讲那条街吗？')) as model:
            turn = await self.client.post(path + '/turns', json={
                'request_id': uuid.uuid4().hex, 'session_id': tid,
                'text': '青禾故乡有一条老街', 'audio_base64': wav(),
            })
            self.assertEqual(turn.status_code, 200, turn.text)
            self.assertIn('故乡的轮廓', model.call_args.args[1])
            self.assertIn('想跳过', model.call_args.args[0])
            self.assertNotIn('家里哪位长辈', model.call_args.args[1])
            self.assertEqual(len((await self.client.get(path, params={'session_id': other_topic})).json()['messages']), 1)
        opened = await self.client.put(
            f'/api/books/{bid}/topics/{tid}/active', params={'include_messages': 'true'},
        )
        self.assertEqual(opened.status_code, 200, opened.text)
        self.assertEqual(opened.json()['active_id'], tid)
        self.assertEqual(opened.json()['messages'],
                         (await self.client.get(path, params={'session_id': tid})).json()['messages'])
        self.assertEqual(opened.json()['messages'][1]['has_audio'], 1)
        self.assertEqual((await self.client.put(f'/api/books/{bid}/topics/{tid}/active')).json(),
                         {'active_id': tid})
        mid = turn.json()['user_id']
        with patch.object(backend, 'llm', AsyncMock(return_value=json.dumps({'items': [{
            'kind': 'story', 'source_id': mid, 'quote': '青禾故乡有一条老街', 'title': '青禾老街',
            'content': '青禾故乡有一条老街', 'tags': ['青禾'],
        }]}))):
            self.assertEqual(await memory_worker.extract(bid), 'processed')
        book_input = {'id': uuid.uuid4().hex, 'title': '另一本', 'name': '奶奶', 'author': '小林'}
        new = await self.client.post('/api/books', json=book_input)
        other = new.json()['id']
        self.assertEqual((await self.client.post('/api/books', json=book_input)).json()['id'], other)
        self.assertEqual(len((await self.client.get('/api/books')).json()['books']), 2)
        await self.open_topic(other)
        self.assertEqual((await self.client.get(f'/api/people/{other}/memories')).json()['items'], [])
        self.assertEqual((await backend.recall(other, '青禾老街'))[1], [])
        self.assertTrue((await backend.recall(bid, '青禾老街'))[1])
        self.assertEqual((await self.client.put(f'/api/books/{other}/topics/{tid}/active')).status_code, 404)
        drafts = f'/api/books/{bid}/topics/{tid}/draft'
        self.assertEqual(await book_api.make_draft(bid, tid, automatic=True), 'insufficient')
        with patch.object(backend, 'llm', AsyncMock(return_value=json.dumps({'body': '我的故乡有一条老街。', 'source_ids': [mid]}))):
            self.assertEqual((await self.client.post(drafts)).json()['outcome'], 'created')
        self.assertEqual((await self.client.get(f'/api/books/{bid}/chapters')).json(), [])
        proposal = (await self.client.get(drafts)).json()['draft']
        cid = (await self.client.put(f"{drafts}/{proposal['id']}")).json()['id']
        share = await self.client.post(f'/api/chapters/{cid}/share')
        token = share.json()['url'].rsplit('/', 1)[-1]
        self.assertEqual((await self.client.get(f'/listen/{token}/audio/{mid}')).status_code, 200)
        metadata = {'title': ' 旧日老街 ', 'author': ' 小林 '}
        updated = await self.client.patch(f'/api/books/{bid}', json=metadata)
        self.assertEqual(updated.status_code, 200, updated.text)
        renamed = next(book for book in updated.json()['books'] if book['id'] == bid)
        self.assertEqual((renamed['title'], renamed['author'], renamed['name']), ('旧日老街', '小林', '您'))
        self.assertEqual((renamed['completed_topic_count'], renamed['topic_count'], renamed['character_count']),
                         (1, 26, len('我的故乡有一条老街。')))
        self.assertEqual(updated.json()['active_id'], other)
        self.assertEqual((await self.client.patch(f'/api/books/{bid}', json={**metadata, 'author': ' '})).status_code, 400)
        self.assertEqual((await self.client.get(f'/listen/{token}/audio/{mid}')).status_code, 200)
        outsider = (await self.client.post('/api/bootstrap')).json()['token']
        denied = await self.client.patch(f'/api/books/{bid}', json=metadata,
                                         headers={'Authorization': f'Bearer {outsider}'})
        self.assertEqual(denied.status_code, 404)
        await self.client.delete(f'/api/books/{bid}')
        self.assertEqual((await self.client.patch(f'/api/books/{bid}', json=metadata)).status_code, 404)
        self.assertEqual((await self.client.get(f'/listen/{token}')).status_code, 404)
        self.assertEqual((await self.client.get(path)).status_code, 404)
        await self.client.post(f'/api/books/{bid}/restore')
        self.assertEqual((await self.client.get(f'/listen/{token}/audio/{mid}')).status_code, 200)
        await self.client.delete(f'/api/books/{bid}')
        with closing(backend.db()) as c, c:
            c.execute('UPDATE books SET deleted_at=? WHERE id=?', (int(time.time()) - book_store.TRASH_SECONDS - 1, bid))
        await book_api.maintain(backend.ACCOUNT.get())
        self.assertEqual((await self.client.get(f'/listen/{token}/audio/{mid}')).status_code, 404)
        self.assertFalse((backend.account_dir() / 'audio' / f'{mid}.wav').exists())
        empty = (await self.client.delete(f'/api/books/{other}')).json()
        self.assertEqual((empty['books'], empty['active_id']), ([], None))
        self.assertEqual((await self.client.get('/api/books')).json()['books'], [])
        self.assertEqual((await self.client.post(f'/api/books/{other}/restore')).json()['active_id'], other)

    async def test_daily_drafts_do_not_mix_topics_or_overwrite_edits(self):
        bid = (await self.client.get('/api/books')).json()['active_id']
        tid = await self.open_topic(bid)
        separate = await self.open_topic(bid, 1)
        messages = []

        async def tell(topic, text):
            reply = await self.client.post(f'/api/people/{bid}/turns', json={
                'request_id': uuid.uuid4().hex, 'session_id': topic, 'text': text,
            })
            self.assertEqual(reply.status_code, 200, reply.text)
            return reply.json()['user_id']

        with patch.object(backend, 'llm', AsyncMock(return_value='您慢慢说。')):
            for i in range(2):
                messages.append(await tell(tid, f'故乡的第{i}件往事。' * 12))
            foreign = await tell(separate, '另外一章的内容。' * 15)
        self.assertEqual(await book_api.make_draft(bid, tid, automatic=True), 'insufficient')
        with patch.object(backend, 'llm', AsyncMock(return_value='您慢慢说。')):
            messages.append(await tell(tid, '第三段故乡的故事。'))
        reply = json.dumps({'body': '只整理故乡的正文。', 'source_ids': messages})
        with patch.object(backend, 'llm', AsyncMock(return_value=reply)) as model:
            self.assertEqual((await scheduler.run_once())['created'], 1)
            self.assertNotIn(foreign, model.call_args.args[1])
        drafts = f'/api/books/{bid}/topics/{tid}/draft'
        did = (await self.client.get(drafts)).json()['draft']['id']
        cid = (await self.client.put(f'{drafts}/{did}')).json()['id']
        with patch.object(backend, 'llm', AsyncMock(return_value='您慢慢说。')):
            new = await tell(tid, '补充一段新往事。')
        with patch.object(backend, 'llm', AsyncMock(return_value=json.dumps({
            'body': '模型生成的新正文。', 'source_ids': [new],
        }))):
            self.assertEqual((await self.client.post(drafts)).json()['outcome'], 'created')
        did = (await self.client.get(drafts)).json()['draft']['id']
        self.assertEqual((await self.client.put(f'/api/chapters/{cid}', json={
            'title': '手工标题', 'content': '手工编辑的正文。',
        })).status_code, 200)
        self.assertEqual((await self.client.put(f'{drafts}/{did}')).status_code, 409)
        saved = (await self.client.get(f'/api/books/{bid}/chapters')).json()
        self.assertEqual((saved[0]['title'], saved[0]['content']), ('手工标题', '手工编辑的正文。'))
        book, = (await self.client.get('/api/books')).json()['books']
        self.assertEqual((book['completed_topic_count'], book['character_count']), (1, len('手工编辑的正文。')))

    async def test_legacy_migration_retains_qr_and_retires_old_sources(self):
        p = (await self.client.get('/api/current-person')).json()['id']
        path = f'/api/people/{p}'
        mid = (await self.client.post(path + '/answers', json={'text': '原始口述', 'audio_base64': wav()})).json()['id']
        with patch.object(backend, 'llm', AsyncMock(return_value='{"title":"已经成书","content":"保留的正文"}')):
            cid = (await self.client.post(path + '/chapters/generate')).json()['id']
        token = (await self.client.post(f'/api/chapters/{cid}/share')).json()['url'].rsplit('/', 1)[-1]
        obsolete = (await self.client.post(path + '/answers', json={'text': '清除旧口述', 'audio_base64': wav()})).json()['id']
        with patch.object(backend, 'llm', AsyncMock(return_value=json.dumps({'items': [{
            'kind': 'story', 'source_id': mid, 'quote': '原始口述',
            'title': '旧事', 'content': '原始口述', 'tags': [],
        }]}))):
            self.assertEqual(await memory_worker.extract(p), 'processed')
        remembered = (await self.client.get(path + '/memories')).json()['items'][0]['id']
        self.assertEqual((await self.client.get('/api/books')).status_code, 503)
        with patch.dict(os.environ, {'LIFEPAGES_ALLOW_BOOK_MIGRATION': '1'}):
            for _ in range(2):
                shelf = await self.client.get('/api/books')
                self.assertEqual(shelf.status_code, 200, shelf.text)
                self.assertEqual(shelf.json()['active_id'], p)
        chapters = (await self.client.get(f'/api/books/{p}/chapters')).json()
        self.assertEqual((chapters[0]['id'], chapters[0]['content']), (cid, '保留的正文'))
        book, = shelf.json()['books']
        self.assertEqual((book['chapter_count'], book['completed_topic_count'], book['character_count']),
                         (1, 0, len('保留的正文')))
        self.assertEqual((await self.client.get(path)).json()['messages'], [])
        self.assertEqual((await self.client.get(f'/listen/{token}/audio/{mid}')).status_code, 200)
        self.assertEqual((await self.client.post(path + '/answers', json={'text': '过期草稿'})).status_code, 409)
        self.assertEqual((await self.client.get(path + '/memories')).json()['items'], [])
        with patch.dict(os.environ, {'LIFEPAGES_QDRANT_URL': 'http://vector.test'}), patch.object(
            book_api.VectorIndex, 'sync', AsyncMock(),
        ) as vector:
            await book_api.maintain(backend.ACCOUNT.get())
            vector.assert_awaited_once_with(backend.ACCOUNT.get(), p, [{'id': remembered, 'status': 'deleted'}])
        self.assertFalse((backend.account_dir() / 'audio' / f'{obsolete}.wav').exists())
        self.assertTrue((backend.account_dir() / 'audio' / f'{mid}.wav').exists())
        self.assertEqual(memory_worker.snapshot(p)[1], [])
