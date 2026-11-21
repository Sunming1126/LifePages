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
        return json.loads(call(method, path, body, expected, auth))

    try:
        call('GET', '/api/books', expected=401, auth=False)
        token = api('POST', '/api/bootstrap', {}, auth=False)['token']
        with sqlite3.connect(args.data / 'registry.sqlite3') as c:
            row = c.execute('SELECT id FROM accounts WHERE token_hash=?',
                            (hashlib.sha256(token.encode()).hexdigest(),)).fetchone()
            assert row
            account = row[0]
        assert re.fullmatch(r'[0-9a-f]{32}', account)
        shelf = api('GET', '/api/books')
        assert shelf['interview_versions'] == [1, 2]
        legacy_id = shelf['books'][0]['id']
        old = api('POST', f'/api/books/{legacy_id}/interview')
        assert old['interview'].get('version', 1) == 1
        api('POST', f'/api/people/{legacy_id}/turns', {
            'request_id': uuid.uuid4().hex, 'session_id': old['active_id'],
            'text': '开始访谈', 'interview_action': 'begin', 'interview_revision': old['interview']['revision']})
        for text in ('最先想起四合院里厨房的灶台', '可以啊'):
            reply = api('POST', f'/api/people/{legacy_id}/turns', {
                'request_id': uuid.uuid4().hex, 'session_id': old['active_id'], 'text': text})
            assert reply['text'].endswith(('？', '?')), reply['text']
            assert not any(t in reply['text'] for t in ('接着聊刚才', '想到什么就从哪里', '能讲一回')), reply['text']
            print(json.dumps({'legacy_agreement_replay': {'user': text, 'reply': reply['text']}}, ensure_ascii=False), flush=True)
        print('OLD_BOOK_V1_OK', flush=True)
        bid = api('POST', '/api/books', {'title': '部署虚构验证', 'author': '测试', 'name': '林老师',
                                       'interview': True, 'interview_version': 2})['id']
        assert api('GET', '/api/books?include_chat=true')['active_id'] == bid
        blank_id = api('GET', f'/api/books/{bid}/topics?editor=true&include_manuscript=true&interview_only=true')['active_id']
        path = f'/api/books/{bid}/interview'
        opened = api('POST', path)
        sid, revision = opened['active_id'], opened['interview']['revision']
        assert opened['interview']['version'] == 2

        def turn(text, action=None, voice=False):
            nonlocal revision
            body = {'request_id': uuid.uuid4().hex, 'session_id': sid, 'text': text}
            if action:
                body.update(interview_action=action, interview_revision=revision)
            raw_voice = None
            if voice:
                buf = io.BytesIO()
                with wave.open(buf, 'wb') as w:
                    w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000); w.writeframes(b'\0\0' * 100)
                raw_voice = buf.getvalue()
                body.update(audio_base64=base64.b64encode(raw_voice).decode(), speak=True)
                events = [json.loads(line) for line in call('POST', f'/api/people/{bid}/turns/stream', body).splitlines()]
                result = events[-1]
                assert result['type'] == 'done', json.dumps(result, ensure_ascii=False)
                assert ''.join(e['text'] for e in events if e['type'] == 'delta') == result['text']
                assert any(e['type'] == 'speech' for e in events)
            else:
                result = api('POST', f'/api/people/{bid}/turns', body)
            revision = result['interview']['revision']
            print(json.dumps({'synthetic_turn': {'state': result['interview'], 'reply': result['text']}}, ensure_ascii=False), flush=True)
            return result, raw_voice

        replay_bid = api('POST', '/api/books', {'title': '虚构灶台对话', 'author': '测试', 'name': '测试',
                                       'interview': True, 'interview_version': 2})['id']
        replay = api('POST', f'/api/books/{replay_bid}/interview')
        editor_path = f'/api/books/{replay_bid}/topics?editor=true&include_manuscript=true&interview_only=true'
        editor = api('GET', editor_path)
        assert len(editor['topics']) == 1 and editor['manuscript']['blocks'] == []
        assert api('GET', editor_path)['active_id'] == editor['active_id']
        assert api('GET', f'/api/books/{replay_bid}/chapters') == []
        print('FULL_EMPTY_EDITOR_IDEMPOTENT_OK', flush=True)
        replay_characters = 0
        for text in ('开始访谈', '最先想起四合院里厨房的灶台', '可以啊'):
            body = {'request_id': uuid.uuid4().hex, 'session_id': replay['active_id'], 'text': text}
            if text == '开始访谈':
                body.update(interview_action='begin', interview_revision=replay['interview']['revision'])
            replay_reply = api('POST', f'/api/people/{replay_bid}/turns', body)
            assert replay_reply['text'].endswith(('？', '?')), replay_reply['text']
            assert '我们可以接着聊刚才这段往事' not in replay_reply['text']
            if text in ('最先想起四合院里厨房的灶台', '可以啊'):
                assert any(word in replay_reply['text'] for word in ('灶台', '厨房', '做饭', '烧火')), replay_reply['text']
            if text == '可以啊':
                assert replay_reply['interview']['characters'] == replay_characters
            replay_characters = replay_reply['interview']['characters']
            print(json.dumps({'v2_agreement_replay': {'user': text, 'reply': replay_reply['text']}}, ensure_ascii=False), flush=True)
        moved = api('POST', f'/api/people/{replay_bid}/turns', {
            'request_id': uuid.uuid4().hex, 'session_id': replay['active_id'],
            'text': '下一章节', 'interview_action': 'next',
            'interview_revision': replay_reply['interview']['revision']})
        assert moved['interview']['question'] == 2 and not moved['interview']['can_draft']
        assert moved['interview']['can_advance'] is False
        with sqlite3.connect(args.data / 'accounts' / account / 'lifepages.sqlite3') as c:
            pending = json.loads(c.execute('SELECT document FROM interview_v2_state WHERE book_id=?', (replay_bid,)).fetchone()[0])
        assert pending['themes']['t01']['status'] == 'pending'
        print('EARLY_NEXT_CHAPTER_PRESERVES_PENDING_OK', flush=True)
        current, _ = turn('开始访谈', 'begin')
        seen = {current['text'].splitlines()[-1]}
        for _ in range(3):
            payload = {'request_id': uuid.uuid4().hex, 'text': current['text'], 'revision': revision}
            refreshed = api('POST', f"{path}/messages/{current['assistant_id']}/refresh", payload)
            assert api('POST', f"{path}/messages/{current['assistant_id']}/refresh", payload) == refreshed
            revision = refreshed['interview']['revision']
            question = refreshed['text'].splitlines()[-1]
            assert question not in seen
            seen.add(question)
            current['text'] = refreshed['text']
        assert len(seen) == 4
        print('NEW_BOOK_RANDOM_REFRESH_RETRY_OK', flush=True)
        answer, original = turn(STORY, voice=True)
        if answer['interview']['question'] == 1:
            answer, _ = turn('这件事的经过已经全部讲完，没有别的情节了。')
        with sqlite3.connect(args.data / 'accounts' / account / 'lifepages.sqlite3') as c:
            document = json.loads(c.execute('SELECT document FROM interview_v2_state WHERE book_id=?', (bid,)).fetchone()[0])
        entry = document['themes']['t01']
        print(json.dumps({'synthetic_quality': {'state': answer['interview'], 'reply': answer['text'],
            'criteria': {key: [cell['level'] for cell in cells] for key,cells in entry['criteria'].items()},
            'core': [bool(cell) for cell in entry['core']], 'story_unit': bool(entry['story_unit'])}}, ensure_ascii=False), flush=True)
        assert answer['interview']['question'] == 2 and answer['interview']['can_draft']
        draft = api('POST', path + '/draft')['draft']
        assert len(draft['chapters']) == 1
        chapter = api('PUT', path + '/draft/' + draft['id'], {'chapters': draft['chapters']})['chapter_ids'][0]
        listed = api('GET', f'/api/books/{bid}/chapters?include_material=true&interview_only=true')
        assert listed[0]['topic_id'] == blank_id
        recording = next(n for n in listed[0]['narrations'] if n['has_audio'])
        assert call('GET', f"/api/messages/{recording['id']}/audio") == original
        share = api('POST', f'/api/chapters/{chapter}/share?include_topic_audio=true')
        share_token = share['url'].rsplit('/', 1)[1]
        call('GET', '/listen/' + share_token, auth=False)
        assert call('GET', f"/listen/{share_token}/audio/{recording['id']}", auth=False) == original
        api('DELETE', f'/api/chapters/{chapter}/shares')
        call('GET', '/listen/' + share_token, expected=404, auth=False)
        print('STORY_GATE_STREAM_CHAPTER_AUDIO_SHARE_OK', flush=True)
    finally:
        if account:
            with sqlite3.connect(args.data / 'registry.sqlite3') as c:
                c.execute('DELETE FROM share_lookup WHERE account_id=?', (account,))
                c.execute('DELETE FROM accounts WHERE id=?', (account,))
            shutil.rmtree(args.data / 'accounts' / account)
            print('SYNTHETIC_ACCOUNT_REMOVED', flush=True)


if __name__ == '__main__':
    main()
