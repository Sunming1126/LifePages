"""Paid real-model QA against a temporary ASGI database, never production books.

python -B tool/smoke_interview_v2.py --config-file /private/path/api_key.txt
Only the existing model provider is contacted. No app/device/service is started.
"""
import argparse
import asyncio
import json
import os
import re
import sys
import tempfile
import uuid
from contextlib import closing
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

STORY = (
    '小时候我住在石桥镇，家到集市要走过一座小石桥。十来岁的时候，每逢赶集我都帮母亲送豆腐。'
    '那年夏天的一天，天还没亮母亲就把豆腐切好，放进两只木桶，桶边垫上湿纱布。我挑不动，'
    '就用家里的小木车推过去。路上最难走的是桥头那段斜坡，车轮压在石缝里总往旁边偏。'
    '有一回走到半路突然下雨，我先把车推进路边的棚子，把自己的旧褂子盖在桶上。'
    '雨小了一些，我才继续走。推到桥头时右边车轮又卡住了，我试着往前硬推，桶里的水就晃出来。'
    '后来我想起父亲平时修车的办法，在路旁捡了一块扁石头垫进缝里，先抬起车头，再一点点往前挪。'
    '过桥后母亲已经在摊位边等着，她先帮我把木桶搬下来，再用布擦掉桶边溅上的泥。'
    '那天豆腐没有碰碎，卖完以后我拿着母亲留的两个铜板买了一张红纸，回家剪成窗花。'
    '从那以后，每次走那座桥我都记得提前把车轮对准平整的石面。后来桥头修平了，'
    '我再经过时还会想起当年自己蹲在雨里垫石头的样子。那一回的经过到这里就讲完了。'
)


async def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config-file', type=Path)
    parser.add_argument('--quick', action='store_true', help='Only verify the complete-story and chapter path')
    parser.add_argument('--output', type=Path, default=Path('artifacts/interview-v2-live.json'))
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='lifepages-v2-qa-') as directory:
        os.environ['LIFEPAGES_DATA'] = directory
        os.environ['LIFEPAGES_ACCESS_TOKEN'] = 'synthetic-interview-v2-qa-only'
        from server import app as backend, interview_v2
        import httpx
        config = backend.read_llm_config
        if args.config_file:
            text = args.config_file.read_text(encoding='utf-8')
            key = next(iter(re.findall(r'\b(?:sk|ark)-[A-Za-z0-9_-]{12,}', text)), '')
            base = next(iter(re.findall(r'https://[^\s]+', text)), 'https://ark.cn-beijing.volces.com/api/coding/v3')
            model = next(iter(re.findall(r'deepseek-v4\.1-flash', text, re.I)), 'deepseek-v4.1-flash')
            if not key:
                raise RuntimeError('No model credential in the supplied private config')
            config = lambda: (key, base.rstrip('/'), model)
        report = {'isolation': 'temporary ASGI database; fictional material only', 'turns': [], 'judgments': []}
        real_llm = backend.llm
        async def model_call(system, context, **kwargs):
            raw = await real_llm(system, context, **kwargs)
            try:
                parsed = json.loads(re.sub(r'^\s*```(?:json)?\s*|\s*```\s*$', '', raw.strip()))
                report['judgments'].append(parsed)
            except ValueError:
                report['judgments'].append({'invalid_json': True})
            return raw
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=backend.app), base_url='http://qa') as client:
            token = (await client.post('/api/bootstrap')).json()['token']
            client.headers['Authorization'] = 'Bearer ' + token
            created = await client.post('/api/books', json={'title': '虚构的桥边往事', 'name': '林老师',
                'author': '虚构测试', 'interview': True, 'interview_version': 2})
            created.raise_for_status()
            bid = created.json()['id']
            opened = (await client.post(f'/api/books/{bid}/interview')).json()
            sid, revision = opened['active_id'], opened['interview']['revision']
            async def turn(text, action=None):
                nonlocal revision
                body = {'session_id': sid, 'request_id': uuid.uuid4().hex, 'text': text}
                if action:
                    body.update(interview_action=action, interview_revision=revision)
                response = await client.post(f'/api/people/{bid}/turns', json=body)
                if response.status_code != 200:
                    raise RuntimeError(f'QA turn failed ({response.status_code}): {response.text}')
                data = response.json()
                revision = data['interview']['revision']
                report['turns'].append({'user': text, 'assistant': data['text'], 'state': data['interview']})
                print(json.dumps({'turn': len(report['turns']), 'question': data['interview']['question'],
                                  'characters': data['interview']['characters'], 'reply': data['text']}, ensure_ascii=False), flush=True)
                return data
            with patch.object(backend, 'read_llm_config', side_effect=config), patch.object(backend, 'llm', side_effect=model_call):
                try:
                    await turn('开始访谈', 'begin')
                    if not args.quick:
                        short = await turn('小时候家在石桥镇，我常沿着村口小路走到集市，跟母亲送豆腐。')
                        assert short['interview']['question'] == 1 and not short['interview']['can_draft']
                        await turn('我不知道还能聊什么，别的细节有些记不清。')
                        await turn('那一点还是想不起来了。')
                    story = await turn(STORY)
                    if story['interview']['question'] == 1:
                        story = await turn('那件事情已经全部讲完，没有别的经过了。')
                    report['completed_theme'] = story['interview']['question'] == 2
                    if story['interview']['can_draft']:
                        draft = await client.post(f'/api/books/{bid}/interview/draft')
                        draft.raise_for_status()
                        report['draft'] = draft.json()['draft']
                        assert len(report['draft']['chapters']) == 1
                    backend.authorized('Bearer ' + token)
                    with closing(backend.db()) as c:
                        report['theme_state'] = interview_v2.load(c, bid)['themes']['t01']
                    assert report['completed_theme'], 'Real model did not judge the completed story sufficient'
                    report['passed'] = True
                finally:
                    args.output.parent.mkdir(parents=True, exist_ok=True)
                    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
                    print(f'QA report: {args.output.resolve()}', flush=True)


if __name__ == '__main__':
    asyncio.run(main())
