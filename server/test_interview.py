import base64
import json
import unittest
import uuid
from contextlib import closing
from unittest.mock import AsyncMock, patch

from server.test_app import backend, httpx, wav
from server import interview, interview_api
from server.interview_questions import DEPTH, V1, rubric


# Each example is written as rubric evidence. Omitting the final fragment
# gives a relevant but incomplete answer to the same question.
EXAMPLES = (
    ('河东巷的院子', '我常在井台边捏泥人'),
    ('邻居小树', '我们偷看戏时从木凳上跌下来'),
    ('我的外婆', '每次赶集回来都会给邻居留一块糖'),
    ('我负责烧火', '先塞一把稻草再添木柴'),
    ('年三十全家包饺子', '爷爷会挑一个饺子塞进一枚洗净的硬币'),
    ('祖父的铜烟盒', '我离家那天他把它送给了我'),
    ('村里的识字班', '老师让我在墙上写头一个字'),
    ('补渔网', '我用旧绳每天练打结'),
    ('我想当画匠', '每天放学都画路边那座桥'),
    ('第一次一个人去外县看病', '我自己查了车次和票价'),
    ('头一份工作是在厂里挡车', '第一天梭子飞出去打断了一根线'),
    ('织机总在换班时停', '我给交接的人写了巡检表'),
    ('同桌阿桥', '下雨那回我们抬着车过桥'),
    ('那人叫小禾', '我们在候车室拼坐一条凳', '后来她教我开起第一间小铺'),
    ('我照顾哥哥', '他骨折时我每天替他取药'),
    ('外甥来家里过暑假', '我们一块用碎布缝了只风筝'),
    ('我从村里搬到西城', '因为那边车间招学徒'),
    ('老街', '从前是青石板路，后来铺成了柏油路'),
    ('视频电话', '我每周都能看见外地女儿吃晚饭'),
    ('我决定关了杂货铺回学校读书', '后来凭证书进了电厂'),
    ('一场意外火灾烧了仓库', '之后全家靠修车生活'),
    ('厂里突然停工三个月', '邻居帮我找到夜班'),
    ('搬到新县城后改做木工', '我挨户问有没有需要修桌椅的'),
    ('我给村里搭成了第一座便桥', '三个月每天傍晚搬石头'),
    ('孩子第一次独自出门', '当时觉得他不懂事，后来才懂他想自己试试'),
    ('去外地多年的老周', '每天出门先吹一声口哨叫狗'),
    ('每天傍晚', '我和老伴沿河散步'),
    ('我家晒酱的做法', '豆子用布盖住后晒足七天'),
    ('有求于人也要记得回报', '我失业时向邻居借工具，后来带他的孩子学修车'),
    ('我想讲渡口停运那一天', '船靠岸时大家把旧绳卷起来送给摆渡人'),
)


def ref(mid, quote):
    return {'id': mid, 'quote': quote}


def score(cells, details=(), *, question=None, intent='answer', withdrawn=()):
    return {'criteria': cells, 'material': list(details), 'withdrawn': list(withdrawn),
            'question': question, 'intent': intent}


class RubricTests(unittest.TestCase):
    def test_each_topic_has_distinct_story_depth_and_its_own_followups(self):
        self.assertEqual(len(DEPTH), 30)
        self.assertEqual(len({row[0] for row in DEPTH}), 30)
        for number, parts in enumerate(EXAMPLES, 1):
            with self.subTest(direction=V1[number - 1].direction):
                criteria = rubric(V1, number)
                prompts = DEPTH[number - 1][1]
                self.assertEqual(len(prompts), len(criteria) + 1)
                self.assertTrue(all(prompt.count('？') == 1 for prompt in prompts))
                evidence = [[ref('answer', part)] for part in parts] + [None]
                incomplete = interview.remember(None, score(evidence), criteria, {'answer': '。'.join(parts)})
                self.assertFalse(interview.passed(incomplete))
                depth = '后来那件事有了一个具体结果'
                complete = interview.remember(incomplete, score([None] * len(parts) + [[ref('more', depth)]]),
                    criteria, {'answer': '。'.join(parts), 'more': depth})
                self.assertTrue(interview.passed(complete))

    def test_explicit_navigation_and_deduplicated_character_count(self):
        self.assertEqual(interview.requested_action('我当时在厂里挡车。可以进入下一个话题了！'), ('next', False))
        self.assertEqual(interview.requested_action('先生让我们做下一题。'), (None, False))
        self.assertEqual(interview.requested_action('跳过这题。'), ('skip', True))
        refs = [ref('a', '井台边捏泥人。'), ref('a', '边捏泥人。祖父替我挑水。'), ref('b', '井台边捏泥人！')]
        sources = {'a': '井台边捏泥人。祖父替我挑水。', 'b': '井台边捏泥人！'}
        self.assertEqual(interview.interview_memory.count_material(refs, sources), 12)


class InterviewTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.client = httpx.AsyncClient(transport=httpx.ASGITransport(app=backend.app), base_url='http://test')
        self.token = (await self.client.post('/api/bootstrap')).json()['token']
        self.client.headers['Authorization'] = f'Bearer {self.token}'
        self.bid = (await self.client.get('/api/books')).json()['active_id']
        self.path = f'/api/books/{self.bid}/interview'

    async def asyncTearDown(self):
        await self.client.aclose()

    async def open(self):
        response = await self.client.post(self.path)
        self.assertEqual(response.status_code, 200, response.text)
        data = response.json()
        self.session = data['active_id']
        self.revision = data['interview']['revision']
        return data

    async def turn(self, text, model=None, *, action=None, deferred_wav=None, request_id=None):
        payload = {'session_id': self.session, 'request_id': request_id or uuid.uuid4().hex, 'text': text}
        if action:
            payload.update(interview_action=action, interview_revision=self.revision)
        path = f'/api/people/{self.bid}/turns'

        async def output(_, context, *, json_mode):
            self.assertTrue(json_mode)
            data = json.loads(context)
            return json.dumps(model(data), ensure_ascii=False)

        with patch.object(backend, 'llm', AsyncMock(side_effect=output)):
            if deferred_wav is None:
                response = await self.client.post(path, json=payload)
                self.assertEqual(response.status_code, 200, response.text)
                data = response.json()
            else:
                payload['payload_hash'] = backend.turn_digest(text, deferred_wav)
                response = await self.client.post(path.replace('/turns', '/voice-turns/stream'), json=payload)
                self.assertEqual(response.status_code, 200, response.text)
                data = [json.loads(line) for line in response.text.splitlines()][-1]
                self.assertEqual(data['type'], 'done', data)
        self.revision = data['interview']['revision']
        return data, payload['request_id']

    async def test_permission_question_is_regenerated_before_delivery(self):
        await self.open()
        await self.turn('开始', action='begin')
        calls = 0
        def model(data):
            nonlocal calls
            calls += 1
            if calls == 1:
                return dict(score([None] * 3, [ref(data['turn'], '厨房的灶台')], question=2),
                            followup='能讲一回在灶台那里发生的事吗？')
            self.assertIn('灶台', json.dumps(data, ensure_ascii=False))
            return {'followup': '您小时候在灶台边通常做些什么？'}
        reply, _ = await self.turn('最先想起厨房的灶台', model)
        self.assertEqual(calls, 2)
        self.assertEqual(reply['text'], '您小时候在灶台边通常做些什么？')

    async def test_agreement_keeps_context_and_asks_generated_question(self):
        await self.open()
        await self.turn('开始', action='begin')
        first, _ = await self.turn('最先想起四合院里厨房的灶台', lambda data: dict(
            score([None] * 3, [ref(data['turn'], '四合院里厨房的灶台')]),
            followup='您小时候在灶台边通常做些什么？'))
        self.assertEqual(first['text'], '您小时候在灶台边通常做些什么？')

        def agree(data):
            self.assertIn('灶台', json.dumps(data, ensure_ascii=False))
            return dict(score([None] * 3, intent='off_topic'),
                        followup='在那座灶台边，您记得最清楚的一次做饭是什么情形？')
        reply, _ = await self.turn('可以啊', agree)
        self.assertIn('灶台', reply['text'])
        self.assertTrue(reply['text'].endswith('？'))
        self.assertNotIn('接着聊', reply['text'])
        self.assertEqual(reply['interview']['characters'], first['interview']['characters'])

    async def test_scoped_memory_and_strict_threshold_block_repeated_and_compound_replies(self):
        first = await self.open()
        self.assertEqual(first['messages'][0]['text'], interview.INTRO)
        self.assertEqual(await self.open(), first)
        begin, _ = await self.turn('我姓林，七十上下，住青石市。', lambda _: score([], intent='ready'))
        self.assertTrue(begin['text'].endswith(V1[0].prompt))
        text = '我家住河东巷，我常在井台边捏泥人。'

        def short(data):
            self.assertNotIn('童年玩伴', json.dumps(data, ensure_ascii=False))
            result = score([[ref(data['turn'], '住河东巷')], [ref(data['turn'], '在井台边捏泥人')], None],
                           [ref(data['turn'], text)], question=1)
            # Even if a provider invents a second question, it cannot reach the user.
            result['reply'] = '您在那里常做什么？' + V1[1].prompt
            result['followup'] = '那回在井台边捏泥人时，您是怎么做的？'
            return result

        reply, _ = await self.turn(text, short)
        self.assertEqual(reply['interview']['question'], 1)
        self.assertGreater(reply['interview']['characters'], 0)
        self.assertFalse(reply['interview']['can_draft'])
        self.assertEqual(reply['text'], '那回在井台边捏泥人时，您是怎么做的？')
        self.assertNotIn(V1[1].prompt, reply['text'])
        self.assertEqual((await self.open())['interview'], reply['interview'])

        def off_topic(data):
            self.assertTrue(all(data['known'][:2]))
            return dict(score([None] * 3, question=2, intent='off_topic'),
                        followup='您当时捏泥人的泥巴是从哪儿找来的？')

        unrelated, _ = await self.turn('我已经买好了火车票。' * 100, off_topic)
        self.assertEqual(unrelated['interview']['characters'], reply['interview']['characters'])
        self.assertFalse(unrelated['interview']['can_draft'])
        again, _ = await self.turn(text, lambda data: dict(
            score([None] * 3, [ref(data['turn'], text)], question=2),
            followup='那回捏泥人时，您是怎样把泥人的模样捏出来的？'))
        self.assertEqual(again['interview']['characters'], reply['interview']['characters'])
        self.assertNotEqual(again['text'], reply['text'])

        # Force exactly 300 verified characters on a fresh topic. The sampled
        # linguistic judgment is mocked; the gate and counting are real.
        next_turn, _ = await self.turn('下一题', action='next')
        self.assertEqual(next_turn['interview']['question'], 2)
        self.assertTrue(next_turn['interview']['can_draft'])
        event = '我和邻居一起去看戏，下雨了就把凳子搬到屋檐下。'
        partial, _ = await self.turn(event, lambda data: score(
            [None] * 3, [ref(data['turn'], event)], question=1))
        self.assertEqual(partial['text'], DEPTH[1][1][2])
        await self.turn('跳过这题', action='skip')
        long_answer = ''.join(chr(0x4e00 + i) for i in range(300))

        def full(data):
            self.assertEqual(data['known'], [])
            self.assertNotIn('河东巷', json.dumps(data, ensure_ascii=False))
            detail = [ref(data['turn'], long_answer)]
            return score([detail, detail, detail], detail, question=3)

        boundary, _ = await self.turn(long_answer, full)
        self.assertEqual(boundary['interview']['characters'], 300)
        self.assertEqual(boundary['interview']['question'], 3)
        completed, request_id = await self.turn('龘。', lambda data: score([None] * 3, [ref(data['turn'], '龘')], question=0))
        self.assertEqual(completed['interview']['question'], 4)
        self.assertTrue(completed['text'].endswith(V1[3].prompt))
        self.assertEqual(completed['text'].count('？'), 1)
        duplicate, _ = await self.turn('龘。', request_id=request_id)
        self.assertEqual(completed, duplicate)
        skipped, _ = await self.turn('跳过这题', action='skip')
        self.assertEqual(skipped['interview']['question'], 5)

    async def test_explicit_end_preserves_recorded_material_and_skip_excludes_it(self):
        await self.open()
        await self.turn('开始访谈', action='begin')
        recording = base64.b64decode(wav())
        first = '我住河东巷，常搬着凳子在井台边等祖父。'
        second = '下雪时我们去院墙外拣柴，回来时雪已经压断了梨树枝。'
        returned, request_id = await self.turn(first + second, lambda data: score(
            [[ref(data['turn'], '住河东巷')], [ref(data['turn'], '在井台边等祖父')], [ref(data['turn'], second)]],
            [ref(data['turn'], first), ref(data['turn'], second)], question=3), deferred_wav=recording)
        self.assertEqual(returned['interview']['question'], 1)
        self.assertFalse(returned['interview']['can_draft'])
        path = self.path + '/draft'
        self.assertEqual((await self.client.post(path)).status_code, 409)
        await self.turn('下一题')
        await self.turn('和小树一起去看戏。', lambda data: dict(
            score([None] * 3, [ref(data['turn'], '和小树一起去看戏')]),
            followup='您和小树那天去看戏，路上发生了什么？'))
        await self.turn('跳过这题', action='skip')
        chapter_path = f'/api/books/{self.bid}/chapters?include_material=true&interview_only=true'

        async def write(prompt, context, **_):
            data = json.loads(context)
            self.assertNotIn('小树', context)
            if prompt == interview_api.OUTLINE_PROMPT:
                groups = {1: [], 2: []}
                for passage in data['passages']:
                    groups[2 if '拣柴' in passage['quote'] else 1].append(passage['number'])
                return json.dumps({'chapters': [
                    {'title': '井台边的童年', 'passages': groups[1]},
                    {'title': '风雪老桥', 'passages': groups[2]},
                ]})
            return json.dumps({'body': data['passages'][0]['quote']})

        with patch.object(backend, 'llm', AsyncMock(side_effect=write)):
            response = await self.client.post(path)
            self.assertEqual(response.status_code, 200, response.text)
            draft = response.json()['draft']
        self.assertEqual(len(draft['chapters']), 2)
        self.assertEqual((await self.client.post(path)).json()['draft'], draft)
        chapters = [{'title': '手改标题', 'body': '手改正文'}, draft['chapters'][1]]
        committed = await self.client.put(f"{path}/{draft['id']}", json={'chapters': chapters})
        self.assertEqual(committed.status_code, 200, committed.text)
        self.assertFalse(committed.json()['interview']['can_draft'])
        repeated = await self.client.put(f"{path}/{draft['id']}", json={'chapters': chapters})
        self.assertEqual(committed.json()['chapter_ids'], repeated.json()['chapter_ids'])
        self.assertEqual((await self.client.post(path)).status_code, 409)
        persisted = (await self.client.get(chapter_path)).json()
        self.assertEqual(persisted[0]['title'], '手改标题')
        self.assertEqual(persisted[0]['content'], '手改正文')
        self.assertFalse(persisted[0]['has_audio'])
        upload = await self.client.put(
            f'/api/people/{self.bid}/voice-turns/{request_id}/audio', content=recording)
        self.assertEqual(upload.status_code, 204, upload.text)
        persisted = (await self.client.get(chapter_path)).json()
        self.assertTrue(all(chapter['has_chapter_audio'] for chapter in persisted))
        self.assertNotIn('拣柴', persisted[0]['narrations'][0]['text'])
        share = await self.client.post(f"/api/chapters/{persisted[0]['id']}/share?include_topic_audio=true")
        self.assertEqual(share.status_code, 200, share.text)
        self.assertEqual(share.json()['audio_count'], 1)

    async def test_legacy_visible_and_retirement_cleans_interview_state(self):
        chapter_route = f'/api/books/{self.bid}/topics'
        legacy = (await self.client.get(chapter_route)).json()['topics'][0]['id']
        await self.client.put(f'{chapter_route}/{legacy}/active')
        with patch.object(backend, 'llm', AsyncMock(return_value='我在听。')):
            answer = await self.client.post(f'/api/people/{self.bid}/turns', json={
                'request_id': uuid.uuid4().hex, 'session_id': legacy, 'text': '旧访谈提到河边的院子。'})
        opened = await self.open()
        self.assertNotEqual(legacy, self.session)
        self.assertIn(answer.json()['user_id'], {m['id'] for m in opened['messages']})
        self.assertEqual((await self.client.get(chapter_route + '?editor=true&interview_only=true')).json()['topics'], [])
        await self.client.delete(f'/api/books/{self.bid}')
        backend.authorized(f'Bearer {self.token}')
        with closing(backend.db()) as connection, connection:
            backend.books.purge(connection, self.bid)
            self.assertIsNone(interview.find(connection, self.bid))
