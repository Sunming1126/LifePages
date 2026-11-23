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
            row = c.execute('SELECT id FROM accounts WHERE token_hash=?',
                            (hashlib.sha256(token.encode()).hexdigest(),)).fetchone()
            assert row
            account = row[0]
        assert re.fullmatch(r'[0-9a-f]{32}', account)
        original = api('GET', '/api/books')
        assert set(original['book_modes']) == {'directory', 'companion'}
        legacy = original['books'][0]
        assert legacy['book_mode'] == 'companion'
        assert api('POST', f"/api/books/{legacy['id']}/interview")['interview'].get('version', 1) == 1
        bid = api('POST', '/api/books', {'id': uuid.uuid4().hex, 'title': '虚构目录验收', 'name': '测试',
            'author': '测试', 'book_mode': 'directory'})['id']
        shelf = api('GET', '/api/books?include_chat=true')
        book = next(row for row in shelf['books'] if row['id'] == bid)
        assert book['book_mode'] == 'directory' and book['interview_version'] is None
        path = f'/api/books/{bid}/directory'
        directory = api('GET', path)
        assert len(directory['topics']) == 26
        tid = directory['topics'][0]['id']
        api('POST', f'/api/books/{bid}/interview', expected=409)
        directory = api('PATCH', f'{path}/items/{tid}', {'revision': directory['revision'],
            'title': '石桥边', 'question': '您在石桥边经历过什么难忘的小事？'})
        api('PUT', f'/api/books/{bid}/topics/{tid}/active')
        raw = io.BytesIO()
        with wave.open(raw, 'wb') as voice:
            voice.setnchannels(1); voice.setsampwidth(2); voice.setframerate(16000); voice.writeframes(b'\0\0' * 100)
        original_voice = raw.getvalue()
        turn = api('POST', f'/api/people/{bid}/turns', {'request_id': uuid.uuid4().hex, 'session_id': tid,
            'text': '虚构验收：放学时我常在石桥边等爷爷。有一天下雨，我们在桥头的小铺避雨，爷爷把外套披在我肩上。',
            'audio_base64': base64.b64encode(original_voice).decode()})
        assert turn['text']
        assert call('GET', f"/api/messages/{turn['user_id']}/audio") == original_voice
        row = api('GET', f'/api/books/{bid}/topics/{tid}/manuscript')
        api('PUT', f'/api/books/{bid}/topics/{tid}/manuscript', {'revision': row['revision'],
            'blocks': [{'id': uuid.uuid4().hex, 'kind': 'text', 'text': '虚构原稿：那天我和爷爷在石桥边避雨。'}]})
        chapters = api('GET', f'/api/books/{bid}/chapters')
        assert len(chapters) == 1
        share = api('POST', f"/api/chapters/{chapters[0]['id']}/share?include_topic_audio=true")
        share_token = share['url'].rsplit('/', 1)[1]
        call('GET', '/listen/' + share_token, auth=False)
        ids = [row['id'] for row in reversed(directory['topics'])]
        directory = api('PUT', path + '/order', {'revision': directory['revision'], 'ids': ids})
        assert [row['id'] for row in directory['topics']] == ids
        for item in list(directory['topics']):
            directory = api('POST', f"{path}/items/{item['id']}/archive", {'revision': directory['revision']})
        assert api('GET', f'/api/books/{bid}/chapters') == []
        startup = api('GET', '/api/books?include_chat=true')
        assert startup.get('chat', {'active_id': None})['active_id'] is None
        call('GET', '/listen/' + share_token, auth=False)
        assert call('GET', f"/listen/{share_token}/audio/{turn['user_id']}", auth=False) == original_voice
        directory = api('POST', f'{path}/items/{tid}/restore', {'revision': directory['revision']})
        assert api('GET', f'/api/books/{bid}/chapters')[0]['content'] == '虚构原稿：那天我和爷爷在石桥边避雨。'
        assert api('GET', '/api/books?include_chat=true')['chat']['active_id'] == tid
        print('DIRECTORY_CREATE_PRESET_REORDER_EMPTY_RESTORE_AUDIO_SHARE_OK', flush=True)
        companion = api('POST', '/api/books', {'id': uuid.uuid4().hex, 'title': '虚构陪伴验收', 'name': '测试',
            'author': '测试', 'book_mode': 'companion'})['id']
        opened = api('POST', f'/api/books/{companion}/interview')
        sid = opened['active_id']
        api('POST', f'/api/people/{companion}/turns', {'request_id': uuid.uuid4().hex, 'session_id': sid,
            'text': '开始访谈', 'interview_action': 'begin', 'interview_revision': opened['interview']['revision']})
        told = api('POST', f'/api/people/{companion}/turns', {'request_id': uuid.uuid4().hex, 'session_id': sid,
            'text': '小时候我住在河边的小镇，放学常绕到石桥边，看大人推着木车去集市。有一次下雨，我就在桥头的小铺里等雨停。'})
        assert 30 <= told['interview']['characters'] < 301
        # Only this disposable account's fictional timestamp is backdated to model an hour away.
        db = args.data / 'accounts' / account / 'lifepages.sqlite3'
        with sqlite3.connect(db) as c:
            c.execute("UPDATE messages SET created=datetime('now','-2 hours') WHERE id=?", (told['user_id'],))
        left = int(time.time()) - 3601
        payload = {'request_id': uuid.uuid4().hex, 'left_at': left, 'last_user_id': told['user_id']}
        welcome = api('POST', f'/api/books/{companion}/interview/resume', payload)
        assert welcome['message_id']
        assert api('POST', f'/api/books/{companion}/interview/resume', payload) == welcome
        again = api('POST', f'/api/books/{companion}/interview/resume', {**payload, 'request_id': uuid.uuid4().hex})
        assert again['message_id'] is None
        assert welcome['interview']['characters'] == told['interview']['characters']
        continued = api('POST', f'/api/people/{companion}/turns', {'request_id': uuid.uuid4().hex,
            'session_id': sid, 'text': '继续刚才的聊天'})
        assert continued['interview']['question'] == told['interview']['question']
        assert continued['interview']['characters'] == told['interview']['characters']
        moved = api('POST', f'/api/people/{companion}/turns', {'request_id': uuid.uuid4().hex,
            'session_id': sid, 'text': '开始一个新的话题'})
        assert moved['interview']['question'] == 2 and moved['interview']['characters'] == 0
        for _ in range(90):
            api('GET', f'/api/books/{companion}/topics?editor=true&include_manuscript=true&interview_only=true')
            organized = api('GET', f'/api/books/{companion}/chapters')
            if organized:
                break
            time.sleep(1)
        assert len(organized) == 1 and organized[0]['title']
        print('COMPANION_HOUR_RETURN_DEDUP_CONTINUE_NEXT_AUTO_CHAPTER_OK', flush=True)
        print(json.dumps({'fictional_directory_reply': turn['text'], 'fictional_continue_reply': continued['text'],
                          'short_chapter_title': organized[0]['title']}, ensure_ascii=False), flush=True)
    finally:
        if account:
            with sqlite3.connect(args.data / 'registry.sqlite3') as c:
                c.execute('DELETE FROM share_lookup WHERE account_id=?', (account,))
                c.execute('DELETE FROM accounts WHERE id=?', (account,))
            shutil.rmtree(args.data / 'accounts' / account)
            print('SYNTHETIC_ACCOUNT_REMOVED', flush=True)


if __name__ == '__main__':
    main()
