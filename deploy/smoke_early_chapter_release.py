"""Disposable HTTP release smoke. No existing account or manuscript is opened."""
import argparse
import base64
import hashlib
import io
import json
from pathlib import Path
import re
import shutil
import sqlite3
import sys
import urllib.error
import urllib.request
import time
import uuid
import wave

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tool.smoke_interview_v2 import STORY


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--base', required=True)
    parser.add_argument('--data', type=Path, required=True)
    args = parser.parse_args()
    token, account = None, None

    def call(method, path, body=None, expected=200, auth=True):
        headers = {'Content-Type': 'application/json'}
        if auth and token:
            headers['Authorization'] = 'Bearer ' + token
        request = urllib.request.Request(args.base + path,
            data=json.dumps(body, ensure_ascii=False).encode() if body is not None else None,
            headers=headers, method=method)
        try:
            with urllib.request.urlopen(request, timeout=180) as response:
                status, raw = response.status, response.read()
        except urllib.error.HTTPError as error:
            status, raw = error.code, error.read()
        if status != expected:
            try:
                detail = json.loads(raw).get('detail', '')
            except Exception:
                detail = ''
            raise AssertionError(f'{method} endpoint returned {status}, expected {expected}: {detail}')
        return raw

    def api(method, path, body=None, expected=200, auth=True):
        # The exact request ID is retained: a retry cannot duplicate an answer.
        for attempt in range(3):
            try:
                return json.loads(call(method, path, body, expected, auth))
            except AssertionError as error:
                if attempt == 2 or '/turns' not in path or 'returned 502' not in str(error):
                    raise
                print('MODEL_TURN_RETRY_SAME_REQUEST_ID', flush=True)
                time.sleep(1)

    try:
        call('GET', '/api/books', expected=401, auth=False)
        token = api('POST', '/api/bootstrap', {}, auth=False)['token']
        with sqlite3.connect(args.data / 'registry.sqlite3') as c:
            row = c.execute('SELECT id FROM accounts WHERE token_hash=?',
                            (hashlib.sha256(token.encode()).hexdigest(),)).fetchone()
            assert row
            account = row[0]
        assert re.fullmatch(r'[0-9a-f]{32}', account)
        bid = api('POST', '/api/books', {'title': '虚构短章自动整理', 'author': '测试', 'name': '测试',
                                       'interview': True, 'interview_version': 2})['id']
        opened = api('POST', f'/api/books/{bid}/interview')
        sid = opened['active_id']
        begin = api('POST', f'/api/people/{bid}/turns', {'request_id': uuid.uuid4().hex,
            'session_id': sid, 'text': '开始访谈', 'interview_action': 'begin',
            'interview_revision': opened['interview']['revision']})
        story = '小时候我住在河边的小镇，每天放学要走过一座石桥。有一次下雨，我提着布鞋绕到桥头的小铺里等雨停，老板给我拿了一条干毛巾。'
        told = api('POST', f'/api/people/{bid}/turns', {'request_id': uuid.uuid4().hex,
            'session_id': sid, 'text': story})
        assert 30 <= told['interview']['characters'] < 301, told['interview']
        assert api('GET', f'/api/books/{bid}/chapters') == []
        moved = api('POST', f'/api/people/{bid}/turns', {'request_id': uuid.uuid4().hex,
            'session_id': sid, 'text': '下一章节', 'interview_action': 'next',
            'interview_revision': told['interview']['revision']})
        assert moved['interview']['question'] == 2
        for _ in range(90):
            api('GET', f'/api/books/{bid}/topics?editor=true&include_manuscript=true&interview_only=true')
            chapters = api('GET', f'/api/books/{bid}/chapters?interview_only=true')
            if chapters:
                break
            time.sleep(1)
        assert len(chapters) == 1, 'Short chapter not automatically organized'
        assert chapters[0]['title'] and chapters[0]['content']
        assert len(chapters[0]['content']) < 301, 'Short material was padded into a long chapter'
        print(json.dumps({'early_chapter_characters': told['interview']['characters'],
            'title': chapters[0]['title'], 'body': chapters[0]['content']}, ensure_ascii=False), flush=True)
        print('EARLY_NEXT_30_CHARACTER_AUTO_CHAPTER_OK', flush=True)
    finally:
        if account:
            with sqlite3.connect(args.data / 'registry.sqlite3') as c:
                c.execute('DELETE FROM share_lookup WHERE account_id=?', (account,))
                c.execute('DELETE FROM accounts WHERE id=?', (account,))
            shutil.rmtree(args.data / 'accounts' / account)
            print('SYNTHETIC_ACCOUNT_REMOVED', flush=True)


if __name__ == '__main__':
    main()
