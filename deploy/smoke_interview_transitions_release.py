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
    last_request = 0.0

    def call(method, path, body=None, expected=200, auth=True):
        nonlocal last_request
        # Public API permits 60 requests/minute. Exercise the real proxy without
        # relaxing its limits or spending its burst allowance on test loops.
        if args.base.startswith('https://'):
            time.sleep(max(0, 1.1 - (time.monotonic() - last_request)))
        last_request = time.monotonic()
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
            account = c.execute('SELECT id FROM accounts WHERE token_hash=?',
                (hashlib.sha256(token.encode()).hexdigest(),)).fetchone()[0]
        assert re.fullmatch(r'[0-9a-f]{32}', account)
        assert set(api('GET', '/api/books')['book_modes']) == {'directory', 'companion'}
        bid = api('POST', '/api/books', {'title': '虚构转换验收', 'author': '测试', 'name': '测试',
            'id': uuid.uuid4().hex, 'book_mode': 'companion'})['id']
        path = f'/api/books/{bid}/interview'
        opened = api('POST', path)
        sid = opened['active_id']
        api('POST', f'/api/people/{bid}/turns', {'request_id': uuid.uuid4().hex, 'session_id': sid,
            'text': '开始访谈', 'interview_action': 'begin', 'interview_revision': opened['interview']['revision']})
        body = {'request_id': uuid.uuid4().hex, 'session_id': sid, 'text': STORY, 'speak': False}
        request = urllib.request.Request(args.base + f'/api/people/{bid}/turns/stream',
            data=json.dumps(body, ensure_ascii=False).encode(),
            headers={'Content-Type': 'application/json', 'Authorization': 'Bearer ' + token}, method='POST')
        start, previous, first, heartbeats, complete = time.monotonic(), time.monotonic(), None, 0, None
        with urllib.request.urlopen(request, timeout=20) as response:
            assert 'application/x-ndjson' in response.headers.get('Content-Type', '')
            for line in response:
                now = time.monotonic()
                assert now - previous < 16, 'Stream silent past heartbeat interval'
                first = first if first is not None else now - start
                previous = now
                event = json.loads(line)
                assert event['type'] != 'error', event
                heartbeats += int(event['type'] == 'processing')
                if event['type'] == 'done':
                    complete = event
                    break
        assert complete and complete['text'] and first < 16
        retry = api('POST', f'/api/people/{bid}/turns', {k:v for k,v in body.items() if k != 'speak'})
        assert retry['assistant_id'] == complete['assistant_id']
        if complete['interview']['question'] == 1:
            complete = api('POST', f'/api/people/{bid}/turns', {'request_id': uuid.uuid4().hex,
                'session_id': sid, 'text': '那一回的事情已经全部讲完，没有新的情节了。'})
        assert complete['interview']['question'] == 2 and complete['interview']['characters'] == 0
        db = args.data / 'accounts' / account / 'lifepages.sqlite3'
        def document():
            with sqlite3.connect(db) as c:
                return json.loads(c.execute('SELECT document FROM interview_v2_state WHERE book_id=?', (bid,)).fetchone()[0])
        def verify(reply, number):
            from server.interview_themes import THEMES, QUESTIONS
            entry = document()['themes'][THEMES[number - 1].id]
            last = entry['shown'][-1]
            assert reply['text'].splitlines()[-1] == QUESTIONS[last['id']].prompt
            assert len(reply['text'].splitlines()) >= 2 and reply['text'].splitlines()[0].strip()
        verify(complete, 2)
        original = document()['themes']['t01']['material']
        refresh_path = f"{path}/messages/{complete['assistant_id']}/refresh"
        payload = {'request_id': uuid.uuid4().hex, 'revision': complete['interview']['revision'], 'text': complete['text']}
        refreshed = api('POST', refresh_path, payload)
        verify(refreshed, 2)
        assert refreshed['interview']['characters'] == 0
        assert api('POST', refresh_path, payload) == refreshed
        assert document()['themes']['t01']['material'] == original
        manual = api('POST', f'/api/people/{bid}/turns', {'request_id': uuid.uuid4().hex, 'session_id': sid,
            'text': '下一章节', 'interview_action': 'next', 'interview_revision': refreshed['interview']['revision']})
        assert manual['interview']['question'] == 3 and manual['interview']['characters'] == 0
        verify(manual, 3)
        assert manual['text'].splitlines()[-1] != refreshed['text'].splitlines()[-1]
        chapters = []
        for _ in range(60):
            chapters = api('GET', f'/api/books/{bid}/chapters')
            if chapters: break
            time.sleep(1)
        assert len(chapters) == 1 and chapters[0]['title'] and chapters[0]['content']
        print(json.dumps({'automatic_reply': complete['text'], 'refresh_reply': refreshed['text'],
            'manual_reply': manual['text'], 'chapter_title': chapters[0]['title'],
            'first_stream_event_seconds': round(first,2), 'processing_events': heartbeats}, ensure_ascii=False), flush=True)
        print('CONTEXT_TRANSITIONS_REFRESH_IDEMPOTENCY_STREAM_BACKGROUND_CHAPTER_OK', flush=True)
    finally:
        if account:
            with sqlite3.connect(args.data / 'registry.sqlite3') as c:
                c.execute('DELETE FROM share_lookup WHERE account_id=?', (account,))
                c.execute('DELETE FROM accounts WHERE id=?', (account,))
            shutil.rmtree(args.data / 'accounts' / account)
            print('SYNTHETIC_ACCOUNT_REMOVED', flush=True)


if __name__ == '__main__':
    main()
