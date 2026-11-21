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
        bid = api('POST', '/api/books', {'title': '虚构流式验收', 'author': '测试', 'name': '测试',
                                       'interview': True, 'interview_version': 2})['id']
        opened = api('POST', f'/api/books/{bid}/interview')
        sid = opened['active_id']
        api('POST', f'/api/people/{bid}/turns', {'request_id': uuid.uuid4().hex, 'session_id': sid,
            'text': '开始访谈', 'interview_action': 'begin', 'interview_revision': opened['interview']['revision']})
        body = {'request_id': uuid.uuid4().hex, 'session_id': sid, 'text': STORY, 'speak': False}
        request = urllib.request.Request(args.base + f'/api/people/{bid}/turns/stream',
            data=json.dumps(body, ensure_ascii=False).encode(),
            headers={'Content-Type': 'application/json', 'Authorization': 'Bearer ' + token}, method='POST')
        start, previous, first, heartbeats, final = time.monotonic(), time.monotonic(), None, 0, None
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
                    final = event
                    break
        assert final and final['text'] and first < 16
        retry = api('POST', f'/api/people/{bid}/turns', {k: v for k, v in body.items() if k != 'speak'})
        assert retry['assistant_id'] == final['assistant_id'] and retry['user_id'] == final['user_id']
        print(json.dumps({'stream_first_event_seconds': round(first, 2), 'reply_seconds': round(time.monotonic()-start, 2),
                          'processing_events': heartbeats, 'reply': final['text']}, ensure_ascii=False), flush=True)
        print('STREAM_PROGRESS_REPLY_IDEMPOTENT_RETRY_OK', flush=True)
    finally:
        if account:
            with sqlite3.connect(args.data / 'registry.sqlite3') as c:
                c.execute('DELETE FROM share_lookup WHERE account_id=?', (account,))
                c.execute('DELETE FROM accounts WHERE id=?', (account,))
            shutil.rmtree(args.data / 'accounts' / account)
            print('SYNTHETIC_ACCOUNT_REMOVED', flush=True)


if __name__ == '__main__':
    main()
