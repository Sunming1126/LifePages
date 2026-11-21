import asyncio
import base64
import json
import unittest
import uuid
from contextlib import closing
from unittest.mock import AsyncMock, patch

from server.test_app import backend, httpx, wav
from server import interview, interview_v2, interview_organizer
from server.interview_themes import THEMES, QUESTIONS


def result(data, *, full=False, worthwhile=False, story_open=False, followup='那天您亲手做的哪一步最难？',
           intent='answer', material=True, withdrawn=(), covered=()):
    text = next(row['text'] for row in data['history'] if row['id'] == data['turn'])
    evidence = [{'id': data['turn'], 'quote': text}] if material else []
    return {'intent': intent, 'material': evidence, 'withdrawn': list(withdrawn),
            'criteria': [{'level': 'sufficient' if full else 'clue', 'evidence': evidence} for _ in range(6)],
            'core': [evidence, evidence] if full else [[], []], 'story_unit': evidence if full else [],
            'covered': list(covered), 'story_open': story_open, 'followup_worthwhile': worthwhile,
            'followup': followup, 'ack': '这段经历我记下了。',
            'new_question': '在附近过日子时，您还记得哪次亲手帮忙张罗的事？', 'entry': '附近帮忙张罗'}


class CurriculumTest(unittest.TestCase):
    def test_polite_or_time_padding_cannot_repeat_the_same_question(self):
        shown = [{'text': '那个灶台是用什么材料砌成的？'}]
        self.assertIsNone(interview_v2.valid_question('那个灶台当时是用什么材料砌成的？', shown))
        self.assertIsNone(interview_v2.valid_question('您还记得那个灶台具体是用什么材料砌成的吗？', shown))
        self.assertEqual(interview_v2.valid_question('灶台旁通常是谁在做饭？', shown), '灶台旁通常是谁在做饭？')

    def test_numbered_passages_preserve_full_text_and_reject_invented_ids(self):
        source = {'m': '小时候我住在石桥镇。那天下雨，我把木车推进棚子。'}
        passages = interview_v2.passage_table({'material': []}, source, 'm')
        ids = [p['id'] for p in passages]
        r = interview_v2.resolve_passages({'material_ids': ids,
            'criteria': [{'level': 'sufficient', 'evidence': [ids[1]]}]}, passages)
        self.assertEqual(''.join(x['quote'] for x in r['material']), source['m'])
        self.assertEqual(r['criteria'][0]['evidence'][0]['quote'], passages[1]['quote'])
        normalized = interview_v2.resolve_passages({'material_ids': ['p0001', '2', 'p9999']}, passages)
        self.assertEqual(normalized['material'], r['material'])
        wrapped = interview_v2.resolve_passages({'core': [{'evidence': [1]}, {'id': 2}],
            'story_unit': {'evidence': ['2']}}, passages)
        self.assertEqual(wrapped['core'], [[r['material'][0]], [r['material'][1]]])
        self.assertEqual(wrapped['story_unit'], [r['material'][1]])
        declined = interview_v2.resolve_passages({'story_unit': {'sufficient': False, 'evidence': [1]}}, passages)
        self.assertEqual(declined['story_unit'], [])
        with self.assertRaises(Exception):
            interview_v2.resolve_passages({'material_ids': ['p9999']}, passages)

    def test_ellipsis_recovers_only_exact_source_spans_without_inventing_text(self):
        source = {'m': '小时候我住在石桥镇，家到集市要走过一座小石桥。我用小木车推豆腐过去。'}
        quoted = [{'id': 'm', 'quote': '小时候我住在石桥镇...家到集市要走过一座小石桥。'},
                  {'id': 'm', 'quote': '我用小木车推豆腐过去。…凭空编造的送货过程'}]
        recovered = interview_v2.refs(quoted, source)
        self.assertEqual(len(recovered), 3)
        self.assertTrue(all(r['quote'] in source[r['id']] for r in recovered))
        self.assertFalse(any('凭空' in r['quote'] or '...' in r['quote'] for r in recovered))

    def test_control_clauses_never_fill_the_word_gate(self):
        story = ''.join(chr(0x4e00 + i) for i in range(300))
        text = story + '。可以啊。好。您问吧。下一题。今天就到这里吧。这件事的经过已经全部讲完，没有别的情节了。'
        selected = interview_v2.material_refs([{'id': 'm', 'quote': text}], {'m': text})
        self.assertEqual(interview_v2.interview_memory.count_material(selected, {'m': text}), 300)

    def test_complete_and_distinct_curriculum(self):
        self.assertEqual(len(THEMES), 30)
        self.assertEqual(len(QUESTIONS), 120)
        self.assertEqual(len({q.prompt for q in QUESTIONS.values()}), 120)
        for theme in THEMES:
            self.assertEqual(len(theme.questions), 4)
            self.assertEqual(len(theme.core), 2)
            self.assertTrue(theme.value)
            for q in theme.questions:
                self.assertEqual(q.prompt.count('？'), 1)
                self.assertEqual(len(q.criteria), 6)
                self.assertTrue(q.value and q.applicability and q.backup)
                for cell in q.criteria:
                    self.assertTrue(all(vars(cell).values()))
        self.assertEqual(len({q.criteria for q in QUESTIONS.values()}), 120)


class ThemeFlowTest(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.auto = patch.object(interview_organizer, 'schedule', return_value={'organizing': False})
        self.auto.start()
        self.addCleanup(self.auto.stop)
        self.client = httpx.AsyncClient(transport=httpx.ASGITransport(app=backend.app), base_url='http://test')
        self.token = (await self.client.post('/api/bootstrap')).json()['token']
        self.client.headers['Authorization'] = f'Bearer {self.token}'
        created = await self.client.post('/api/books', json={
            'title': '虚构回忆录', 'author': '测试', 'name': '林老师', 'interview': True, 'interview_version': 2})
        self.assertEqual(created.status_code, 200, created.text)
        self.bid = created.json()['id']
        self.path = f'/api/books/{self.bid}/interview'
        self.opened = (await self.client.post(self.path)).json()
        self.sid = self.opened['active_id']
        self.revision = self.opened['interview']['revision']

    async def asyncTearDown(self):
        await self.client.aclose()

    def document(self):
        backend.authorized(f'Bearer {self.token}')
        with closing(backend.db()) as c:
            return interview_v2.load(c, self.bid)

    async def turn(self, text, factory=None, action=None, *, streaming=False, audio=None, followup_factory=None):
        async def model(system, context, **kwargs):
            data = json.loads(context)
            if 'avoid_questions' in data:
                return json.dumps(followup_factory(data) if followup_factory else
                    {'questions': ['那天您亲手做的哪一步最难？']}, ensure_ascii=False)
            return json.dumps(factory(data) if factory else result(data), ensure_ascii=False)
        body = {'request_id': uuid.uuid4().hex, 'session_id': self.sid, 'text': text}
        if audio:
            body['audio_base64'] = audio
        if action:
            body.update(interview_action=action, interview_revision=self.revision)
        path = f'/api/people/{self.bid}/turns' + ('/stream' if streaming else '')
        with patch.object(backend, 'llm', side_effect=model):
            response = await self.client.post(path, json={**body, **({'speak': True} if streaming else {})})
        self.assertEqual(response.status_code, 200, response.text)
        data = json.loads(response.text.splitlines()[-1]) if streaming else response.json()
        self.revision = data['interview']['revision']
        return data

    async def begin(self):
        data = await self.turn('开始访谈', action='begin')
        self.assertEqual(data['interview']['question'], 1)
        return data

    async def refresh(self, data, *, request_id=None, revision=None):
        body = {'text': data['text'], 'revision': self.revision if revision is None else revision,
                'request_id': request_id or uuid.uuid4().hex}
        response = await self.client.post(f"{self.path}/messages/{data['assistant_id']}/refresh", json=body)
        if response.status_code == 200:
            self.revision = response.json()['interview']['revision']
        return response, body

    async def test_compound_followup_is_repaired_without_abandoning_story(self):
        await self.begin()
        calls = 0
        def model(data):
            nonlocal calls
            calls += 1
            if calls == 1:
                return result(data, worthwhile=True, followup='当时谁在做饭？您在帮忙还是看着？')
            return {'followup': '您小时候在灶台边通常做些什么？'}
        reply = await self.turn('我想起厨房的灶台', model, followup_factory=model)
        self.assertEqual(calls, 2)
        self.assertIn('您小时候在灶台边通常做些什么？', reply['text'])
        before = reply['interview']['characters']
        reply = await self.turn('可以啊', followup_factory=lambda d: {'questions': ['在那个灶台边，您常看见谁做饭？']})
        self.assertEqual(reply['interview']['characters'], before)

    async def test_new_scene_clue_gets_probe_before_switching_curated_entry(self):
        await self.begin()
        current = self.document()['themes']['t01']['current']
        def model(data):
            if 'avoid_questions' in data:
                return {'questions': ['您记得那个灶台是用什么材料砌成的？']}
            return result(data, material=False, worthwhile=False)
        reply = await self.turn('四合院里厨房的灶台', model, followup_factory=model)
        entry = self.document()['themes']['t01']
        self.assertEqual(entry['current'], current)
        self.assertEqual(entry['shown'][-1]['entry'], 'followup')
        self.assertIn('灶台', reply['text'])
        self.assertFalse(reply['interview']['can_draft'])
        self.assertEqual(entry['no_new'], 0)
        reply = await self.turn('可以啊', followup_factory=lambda d:
                               {'questions': ['当时厨房里主要是谁在做饭？']})
        self.assertEqual(self.document()['themes']['t01']['current'], current)
        self.assertEqual(reply['interview']['characters'], 0)

    async def test_incomplete_assessment_is_repaired_without_passing_quality_gate(self):
        await self.begin()
        calls = 0
        def model(data):
            nonlocal calls
            calls += 1
            value = result(data, worthwhile=True)
            if calls == 1:
                value['criteria'] = []
            return value
        reply = await self.turn('我想起厨房的灶台', model)
        self.assertEqual(calls, 2)
        self.assertFalse(reply['interview']['can_draft'])
        self.assertEqual(reply['interview']['question'], 1)

    async def test_version_is_pinned_and_random_order_is_persisted_at_creation(self):
        self.assertEqual(self.opened['interview']['version'], 2)
        original = self.document()
        self.assertTrue(all(sorted(e['order']) == [q.id for q in t.questions]
                            for t, e in zip(THEMES, original['themes'].values())))
        self.assertEqual((await self.client.post(self.path)).json(), self.opened)
        self.assertEqual(self.document(), original)
        shelf = (await self.client.get('/api/books')).json()
        self.assertEqual(next(b['interview_version'] for b in shelf['books'] if b['id'] == self.bid), 2)
        old = next(b for b in shelf['books'] if b['id'] != self.bid)
        self.assertEqual(old['interview_version'], 1)
        legacy = (await self.client.post(f"/api/books/{old['id']}/interview")).json()
        self.assertNotIn('version', legacy['interview'])

    async def test_next_chapter_control_keeps_incomplete_material_pending(self):
        await self.begin()
        await self.turn('我在井台旁玩过泥巴。')
        source = self.document()['themes']['t01']['material']
        moved = await self.turn('下一章节', action='next')
        self.assertEqual(moved['interview']['question'], 2)
        previous = self.document()['themes']['t01']
        self.assertEqual(previous['status'], 'pending')
        self.assertEqual(previous['material'], source)
        self.assertFalse(moved['interview']['can_draft'])

    async def test_short_exhausted_story_changes_question_not_theme(self):
        opening = await self.begin()
        answer = await self.turn('我常走井台旁的路，有一次下雨就从屋檐下绕回家。',
                                 lambda data: result(data, full=True))
        self.assertNotEqual(answer['text'].splitlines()[-1], opening['text'].splitlines()[-1])
        self.assertEqual(answer['interview']['question'], 1)
        self.assertGreater(answer['interview']['characters'], 0)
        self.assertFalse(answer['interview']['can_draft'])
        entry = self.document()['themes']['t01']
        self.assertEqual(len(entry['shown']), 2)
        self.assertTrue(entry['shown'][0]['answered'])

    async def test_word_gate_quality_and_story_open_are_independent(self):
        await self.begin()
        text = ''.join(chr(0x4e00 + i) for i in range(300))
        boundary = await self.turn(text, lambda d: result(d, full=True))
        self.assertEqual(boundary['interview']['characters'], 300)
        self.assertFalse(boundary['interview']['can_advance'])
        self.assertEqual(boundary['interview']['question'], 1)
        opened = await self.turn('龘', lambda d: result(d, full=True, story_open=True, worthwhile=True))
        self.assertEqual(opened['interview']['characters'], 301)
        self.assertTrue(opened['interview']['can_advance'])
        self.assertEqual(opened['interview']['question'], 1)
        closed = await self.turn('事情后来就这样收住了。', lambda d: result(d, full=True))
        self.assertEqual(closed['interview']['question'], 2)
        self.assertTrue(closed['interview']['can_draft'])
        self.assertEqual(self.document()['themes']['t01']['status'], 'complete')

    async def test_many_characters_without_depth_do_not_complete(self):
        await self.begin()
        answer = await self.turn(''.join(chr(0x4e00 + i) for i in range(340)))
        self.assertGreaterEqual(answer['interview']['characters'], 301)
        self.assertFalse(answer['interview']['can_advance'])
        self.assertEqual(answer['interview']['question'], 1)
        self.assertFalse(answer['interview']['can_draft'])

    async def test_explicit_story_end_does_not_force_another_story_after_quality_passes(self):
        await self.begin()
        text = ''.join(chr(0x4e00 + i) for i in range(330)) + '。那一回的经过到这里就讲完了。'
        closed = await self.turn(text, lambda d: result(d, full=True, worthwhile=True))
        self.assertEqual(closed['interview']['question'], 2)
        self.assertTrue(closed['interview']['can_draft'])

    async def test_refresh_is_idempotent_and_cannot_edit_history(self):
        opening = await self.begin()
        revision = self.revision
        response, body = await self.refresh(opening)
        self.assertEqual(response.status_code, 200, response.text)
        self.assertNotEqual(response.json()['text'], opening['text'])
        path = f"{self.path}/messages/{opening['assistant_id']}/refresh"
        repeated = await self.client.post(path, json=body)
        self.assertEqual(repeated.json(), response.json())
        self.assertEqual(len(self.document()['themes']['t01']['shown']), 2)
        conflict = await self.client.post(path, json={**body, 'revision': revision + 1})
        self.assertEqual(conflict.status_code, 409)
        current = {'assistant_id': opening['assistant_id'], 'text': response.json()['text']}
        answered = await self.turn('我记得村口桥边那次赶集。')
        historical, _ = await self.refresh(current)
        self.assertEqual(historical.status_code, 409)
        self.assertEqual(answered['interview']['refresh_message_id'], answered['assistant_id'])

    async def test_curated_pool_never_wraps_and_failure_consumes_nothing(self):
        current = await self.begin()
        observed = {current['text'].splitlines()[-1]}
        for _ in range(3):
            response, _ = await self.refresh(current)
            self.assertEqual(response.status_code, 200, response.text)
            current = {'assistant_id': current['assistant_id'], 'text': response.json()['text']}
            question = current['text'].splitlines()[-1]
            self.assertNotIn(question, observed)
            observed.add(question)
        before = self.document()
        with patch.object(backend, 'llm', AsyncMock(return_value='{}')):
            failed, _ = await self.refresh(current)
        self.assertEqual(failed.status_code, 502)
        self.assertEqual(self.document(), before)
        with patch.object(backend, 'llm', AsyncMock(return_value=json.dumps({
                'question': '在附近过日子时，您还记得哪次帮忙张罗的事？', 'entry': '帮忙张罗'}))):
            extra, _ = await self.refresh(current)
        self.assertEqual(extra.status_code, 200, extra.text)
        self.assertIn('帮忙张罗', extra.json()['text'])
        self.assertEqual(extra.json()['interview']['question'], 1)

    async def test_cannot_recall_has_one_hint_then_switches(self):
        await self.begin()
        hint = await self.turn('我不知道还能讲什么。', lambda d: result(
            d, material=False, intent='cannot_recall', worthwhile=True, followup='您想起那条路时，最先记起哪个拐弯？'))
        self.assertIn('拐弯', hint['text'])
        again = await self.turn('还是想不起来。', lambda d: result(
            d, material=False, intent='cannot_recall', worthwhile=True, followup='那条路旁边您还记得什么东西？'))
        self.assertNotIn('还记得什么东西', again['text'])
        self.assertEqual(len({r['id'] for r in self.document()['themes']['t01']['shown']}), 2)

    async def test_repeated_information_does_not_inflate_count_or_loop(self):
        await self.begin()
        first = await self.turn('我在村口桥边捏泥人。', lambda d: result(d, worthwhile=True, followup='那回泥人是怎样做起来的？'))
        second = await self.turn('我在村口桥边捏泥人。', lambda d: result(d, worthwhile=True, followup='捏泥人时您先做了哪个动作？'))
        third = await self.turn('我在村口桥边捏泥人。', lambda d: result(d, worthwhile=True, followup='那回泥人您怎样收起来的？'))
        self.assertEqual(first['interview']['characters'], second['interview']['characters'])
        self.assertEqual(second['interview']['characters'], third['interview']['characters'])
        self.assertNotIn('怎样收起来', third['text'])

    async def test_withdrawal_reopens_quality_and_preserves_originals(self):
        await self.begin()
        story = ''.join(chr(0x4e00 + i) for i in range(330))
        finished = await self.turn(story, lambda d: result(d, full=True))
        self.assertTrue(finished['interview']['can_draft'])
        withdrawn = await self.turn('刚才那段说错了，别使用。', lambda d: result(d, material=False,
            withdrawn=[{'id': finished['user_id'], 'quote': story}]))
        self.assertFalse(withdrawn['interview']['can_draft'])
        entry = self.document()['themes']['t01']
        self.assertEqual(entry['status'], 'pending')
        self.assertFalse(entry['material'])
        history = (await self.client.post(self.path)).json()['messages']
        self.assertIn(story, [m['text'] for m in history])

    async def test_leave_and_rest_preserve_material_without_short_chapter(self):
        await self.begin()
        first = await self.turn('小时候桥下有个小摊，我常去买纸。')
        leaving = await self.turn('聊点别的。')
        self.assertEqual(leaving['interview']['question'], 2)
        self.assertFalse(leaving['interview']['can_draft'])
        self.assertTrue(self.document()['themes']['t01']['material'])
        rest = await self.turn('今天到这儿。')
        self.assertFalse(rest['interview']['refresh_message_id'])
        self.assertNotIn('？', rest['text'])
        self.assertEqual(rest['interview']['question'], 2)

    async def test_early_next_chapter_29_30_and_300_character_boundaries(self):
        for length in (29, 30, 300):
            with self.subTest(length=length):
                if length != 29:
                    self.bid = (await self.client.post('/api/books', json={
                        'title': '虚构短章', 'author': '测试', 'name': '测试',
                        'interview': True, 'interview_version': 2})).json()['id']
                    self.path = f'/api/books/{self.bid}/interview'
                    opened = (await self.client.post(self.path)).json()
                    self.sid, self.revision = opened['active_id'], opened['interview']['revision']
                await self.begin()
                story = ''.join(chr(0x4e00 + i) for i in range(length))
                await self.turn(story)
                with closing(backend.db()) as c:
                    self.assertEqual(interview_organizer.material(c, self.bid), [])
                moved = await self.turn('下一章节', action='next')
                self.assertEqual(moved['interview']['can_draft'], length >= 30)
                self.assertEqual(moved['interview']['question'], 2)
                self.assertEqual(self.document()['themes']['t01']['status'], 'pending')
                backend.authorized(f'Bearer {self.token}')
                with patch.object(backend, 'llm', AsyncMock(return_value=json.dumps({'title': '短短的回忆', 'body': '按原话保留的短章。'}))):
                    await interview_organizer.run(self.bid)
                chapters = (await self.client.get(f'/api/books/{self.bid}/chapters')).json()
                self.assertEqual(len(chapters), int(length >= 30))

    async def test_next_chapter_reply_finishes_while_organizer_is_blocked(self):
        await self.begin()
        self.auto.stop()
        started, release = asyncio.Event(), asyncio.Event()
        async def slow_chapter(material, existing):
            started.set()
            await release.wait()
            return []
        captured = {}
        def assessment(data):
            captured['next_question'] = data['next_chapter_question']
            assessed = result(data, full=True)
            assessed['ack'] = '这段经历里的细节已经记下了。'
            return assessed
        from server import interview_api
        with patch.object(interview_api, 'generate_theme_chapters', side_effect=slow_chapter):
            reply = await asyncio.wait_for(self.turn(''.join(chr(0x4e00 + i) for i in range(330)),
                assessment, streaming=True), timeout=1)
            self.assertEqual(reply['interview']['question'], 2)
            self.assertEqual(reply['interview']['characters'], 0)
            self.assertTrue(reply['text'].startswith('这段经历里的细节已经记下了。'))
            self.assertTrue(reply['text'].endswith(captured['next_question']))
            await asyncio.wait_for(started.wait(), timeout=1)
            self.assertFalse(release.is_set())
            task = interview_organizer._tasks[(backend.ACCOUNT.get(), self.bid)]
            task.cancel()
            release.set()
            await asyncio.gather(task, return_exceptions=True)

    async def test_background_schedule_deduplicates_and_editor_observes_completion(self):
        await self.begin()
        await self.turn(''.join(chr(0x4e00 + i) for i in range(330)), lambda d: result(d, full=True))
        self.auto.stop()
        backend.authorized(f'Bearer {self.token}')
        entered, release = asyncio.Event(), asyncio.Event()
        async def delayed(*args, **kwargs):
            entered.set()
            await release.wait()
            return json.dumps({'title': '等待后的章名', 'body': '已自动保存的正文'})
        with patch.object(backend, 'llm', side_effect=delayed) as model:
            with closing(backend.db()) as c:
                self.assertTrue(interview_organizer.schedule(c, self.bid)['organizing'])
                self.assertTrue(interview_organizer.schedule(c, self.bid)['organizing'])
            await entered.wait()
            path = f'/api/books/{self.bid}/topics?editor=true&include_manuscript=true&interview_only=true'
            self.assertTrue((await self.client.get(path)).json()['organizing'])
            release.set()
            await interview_organizer._tasks[(backend.ACCOUNT.get(), self.bid)]
            opened = (await self.client.get(path)).json()
            self.assertFalse(opened['organizing'])
            self.assertEqual(opened['topics'][0]['title'], '等待后的章名')
            self.assertEqual(model.call_count, 1)

    async def test_automatic_chapter_is_idempotent_and_titles_directory(self):
        await self.begin()
        original = wav()
        done = await self.turn(''.join(chr(0x4e00 + i) for i in range(330)), lambda d: result(d, full=True), audio=original)
        backend.authorized(f'Bearer {self.token}')
        with patch.object(backend, 'llm', AsyncMock(return_value=json.dumps({'title': '石桥边的清晨', 'body': '这是依据原话整理的虚构正文。'}))):
            await interview_organizer.run(self.bid)
            await interview_organizer.run(self.bid)
        chapters = (await self.client.get(f'/api/books/{self.bid}/chapters?include_material=true&interview_only=true')).json()
        self.assertEqual(len(chapters), 1)
        self.assertEqual(chapters[0]['title'], '石桥边的清晨')
        self.assertEqual({r['id'] for r in chapters[0]['narrations']}, {done['user_id']})
        opened = (await self.client.get(f'/api/books/{self.bid}/topics?editor=true&include_manuscript=true&interview_only=true')).json()
        self.assertEqual(opened['topics'][0]['title'], '石桥边的清晨')
        self.assertIn('虚构正文', opened['manuscript']['blocks'][0]['text'])

    async def test_automatic_failure_keeps_queue_and_correction_cancels_stale_body(self):
        await self.begin()
        story = ''.join(chr(0x4e00 + i) for i in range(330))
        done = await self.turn(story, lambda d: result(d, full=True))
        backend.authorized(f'Bearer {self.token}')
        with patch.object(backend, 'llm', AsyncMock(side_effect=RuntimeError('offline'))):
            await interview_organizer.run(self.bid)
        with closing(backend.db()) as c:
            self.assertTrue(interview_organizer.material(c, self.bid))
        entered, release = asyncio.Event(), asyncio.Event()
        async def delayed(*args, **kwargs):
            entered.set()
            await release.wait()
            return json.dumps({'title': '不应保存', 'body': '过时正文'})
        with patch.object(backend, 'llm', side_effect=delayed):
            task = asyncio.create_task(interview_organizer.run(self.bid))
            await entered.wait()
            await self.turn('刚才那段别使用。', lambda d: result(d, material=False,
                withdrawn=[{'id': done['user_id'], 'quote': story}]))
            release.set()
            await task
        self.assertEqual((await self.client.get(f'/api/books/{self.bid}/chapters')).json(), [])

    async def test_one_theme_one_chapter_with_multiple_questions_and_original_audio(self):
        editor_path = f'/api/books/{self.bid}/topics?editor=true&include_manuscript=true&interview_only=true'
        blank = (await self.client.get(editor_path)).json()['active_id']
        opening = await self.begin()
        original_audio = wav()
        first = await self.turn(''.join(chr(0x4e00 + i) for i in range(170)), lambda d: result(d, full=True), audio=original_audio)
        await self.turn('下一题', action='next')
        last = await self.turn(''.join(chr(0x5000 + i) for i in range(170)), lambda d: result(d, full=True), streaming=True)
        self.assertTrue(last['interview']['can_draft'])
        self.assertEqual(last['interview']['question'], 2)
        backend.authorized(f'Bearer {self.token}')
        with closing(backend.db()) as c:
            segments = [r[0] for r in c.execute('SELECT text FROM rtc_turn_segments ORDER BY segment')]
        self.assertEqual(''.join(segments).replace('\n', ''), last['text'].replace('\n', ''))
        async def write(system, context, **kwargs):
            data = json.loads(context)
            self.assertEqual(len(data['passages']), 2)
            return json.dumps({'title': '桥边旧路', 'body': '\n\n'.join(p['quote'] for p in data['passages'])})
        with patch.object(backend, 'llm', side_effect=write):
            draft = await self.client.post(self.path + '/draft')
        self.assertEqual(draft.status_code, 200, draft.text)
        data = draft.json()['draft']
        self.assertEqual(len(data['chapters']), 1)
        saved = await self.client.put(f"{self.path}/draft/{data['id']}", json={'chapters': data['chapters']})
        self.assertEqual(saved.status_code, 200, saved.text)
        chapters = (await self.client.get(f'/api/books/{self.bid}/chapters?include_material=true&interview_only=true')).json()
        self.assertEqual(len(chapters), 1)
        editor = (await self.client.get(editor_path)).json()
        self.assertEqual(editor['active_id'], blank)
        self.assertEqual(len(editor['topics']), 1)
        self.assertEqual(editor['manuscript']['title'], '桥边旧路')
        self.assertEqual({r['id'] for r in chapters[0]['narrations']}, {first['user_id'], last['user_id']})
        cid = chapters[0]['id']
        shared = await self.client.post(f'/api/chapters/{cid}/share?include_topic_audio=true')
        self.assertEqual(shared.status_code, 200, shared.text)
        share_token = shared.json()['url'].rsplit('/', 1)[-1]
        page = await self.client.get(f'/listen/{share_token}')
        self.assertIn(opening['text'].splitlines()[-1], page.text)
        audio = await self.client.get(f"/listen/{share_token}/audio/{first['user_id']}")
        self.assertEqual(audio.content, base64.b64decode(original_audio))

    async def test_simultaneous_refresh_only_consumes_one_question(self):
        opening = await self.begin()
        body = {'text': opening['text'], 'revision': self.revision, 'request_id': uuid.uuid4().hex}
        path = f"{self.path}/messages/{opening['assistant_id']}/refresh"
        responses = await asyncio.gather(*(self.client.post(path, json=body) for _ in range(2)))
        self.assertTrue(all(r.status_code == 200 for r in responses))
        self.assertEqual(responses[0].json(), responses[1].json())
        self.assertEqual(len(self.document()['themes']['t01']['shown']), 2)

    async def test_unseen_covered_question_is_not_asked_and_foreign_quotes_are_rejected(self):
        await self.begin()
        entry = self.document()['themes']['t01']
        next_id = entry['order'][1]
        def response(data):
            value = result(data)
            value['covered'] = [{'id': next_id, 'evidence': value['material']}]
            return value
        await self.turn('我家到集市的路上常有挑担的人经过，有次我帮他们把担子抬过桥。', response)
        entry = self.document()['themes']['t01']
        self.assertIn(next_id, entry['covered'])
        self.assertNotEqual(entry['current'], next_id)
        def fabricated(data):
            value = result(data, full=True)
            fake = [{'id': 'another-books-message', 'quote': '不能引用的外部故事'}]
            value.update(material=fake, core=[fake, fake], story_unit=fake,
                         criteria=[{'level': 'sufficient', 'evidence': fake}] * 6)
            return value
        before = (await self.client.post(self.path)).json()['interview']['characters']
        reply = await self.turn('随便聊聊。', fabricated)
        self.assertEqual(reply['interview']['characters'], before)
        self.assertFalse(reply['interview']['can_draft'])

    async def test_different_books_do_not_share_a_shuffle_or_question_history(self):
        first = self.document()
        created = (await self.client.post('/api/books', json={
            'title': '另一本虚构回忆录', 'author': '测试', 'name': '林老师', 'interview': True, 'interview_version': 2})).json()
        backend.authorized(f'Bearer {self.token}')
        with closing(backend.db()) as c:
            other = interview_v2.load(c, created['id'])
        # Matching all 30 independent permutations by chance is 24^-30.
        self.assertNotEqual([e['order'] for e in first['themes'].values()],
                            [e['order'] for e in other['themes'].values()])
        await self.begin()
        backend.authorized(f'Bearer {self.token}')
        with closing(backend.db()) as c:
            self.assertFalse(interview_v2.load(c, created['id'])['themes']['t01']['shown'])

    async def test_v2_raises_only_its_own_output_budget(self):
        def reply(request):
            body = json.loads(request.content)
            self.assertEqual(body['max_tokens'], 8192)
            return httpx.Response(200, json={'choices': [
                {'finish_reason': 'stop', 'message': {'content': '{}'}}]})
        provider = httpx.AsyncClient(transport=httpx.MockTransport(reply))
        with patch.object(backend, 'read_llm_config', return_value=('test-key', 'https://model.test', 'test-model')), \
                patch.object(backend.httpx, 'AsyncClient', return_value=provider):
            self.assertEqual(await backend.llm('只输出JSON', '虚构测试', json_mode=True, max_tokens=8192), '{}')

    async def test_story_can_answer_another_question_without_weakening_the_gate(self):
        await self.begin()
        order = self.document()['themes']['t01']['order']
        actual_question = order[1]
        def complete(data):
            value = result(data, full=True)
            value['criteria_question'] = actual_question
            # A string shorthand is still verified against this exact user message.
            value['material'] = [value['material'][0]['quote']]
            return value
        story = ''.join(chr(0x4e00 + i) for i in range(330))
        done = await self.turn(story, complete)
        self.assertEqual(done['interview']['question'], 2)
        self.assertTrue(done['interview']['can_draft'])
        entry = self.document()['themes']['t01']
        self.assertIn(actual_question, entry['covered'])
        self.assertEqual(entry['criteria'][actual_question][0]['level'], 'sufficient')

    async def test_ark_reasoning_control_is_opt_in_and_provider_scoped(self):
        for model, base, opt_in, expected in (
            ('deepseek-v4.1-flash', 'https://ark.cn-beijing.volces.com/api/coding/v3', False, True),
            ('deepseek-v4.1-flash', 'https://ark.cn-beijing.volces.com/api/coding/v3', None, False),
            ('unknown-model', 'https://ark.cn-beijing.volces.com/api/coding/v3', False, False),
            ('deepseek-v4.1-flash', 'https://unverified-provider.test/v1', False, False),
        ):
            with self.subTest(model=model, base=base, opt_in=opt_in):
                def reply(request):
                    body = json.loads(request.content)
                    self.assertEqual('thinking' in body, expected)
                    if expected:
                        self.assertEqual(body['thinking'], {'type': 'disabled'})
                        self.assertEqual(body['response_format'], {'type': 'json_object'})
                    return httpx.Response(200, json={'choices': [
                        {'finish_reason': 'stop', 'message': {'content': '{}'}}]})
                provider = httpx.AsyncClient(transport=httpx.MockTransport(reply))
                with patch.object(backend, 'read_llm_config', return_value=('test-key', base, model)), \
                        patch.object(backend.httpx, 'AsyncClient', return_value=provider):
                    self.assertEqual(await backend.llm('只输出JSON', '虚构测试', json_mode=True, thinking=opt_in), '{}')
