"""Ephemeral, synthetic HTTPS smoke test. Never print credentials or share URLs."""
import asyncio
import base64
import hashlib
import io
import json
import os
import re
import shutil
import sqlite3
import urllib.error
import urllib.request
import wave
import uuid
import websockets

BASE = 'https://onesay.top/lifepages'
REGISTRY = '/opt/lifepages/shared/data/registry.sqlite3'
ACCOUNTS = '/opt/lifepages/shared/data/accounts'
token = None
account = None

def call(method, path, body=None, authenticated=True):
    headers = {'Content-Type': 'application/json'}
    if authenticated and token:
        headers['Authorization'] = 'Bearer ' + token
    data = json.dumps(body, ensure_ascii=False).encode() if body is not None else None
    request = urllib.request.Request(BASE + path, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=240) as result:
            return result.status, result.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()

def expect(method, path, body=None, expected=200, authenticated=True):
    status, content = call(method, path, body, authenticated)
    if status != expected:
        try:
            detail = json.loads(content).get('detail', '')
        except Exception:
            detail = ''
        raise RuntimeError(f'{method} {path.split("/")[1]} returned {status}: {detail}')
    return content

try:
    token = json.loads(expect('POST', '/api/bootstrap', {}, authenticated=False))['token']
    with sqlite3.connect(REGISTRY) as conn:
        row = conn.execute('SELECT id FROM accounts WHERE token_hash=?', (hashlib.sha256(token.encode()).hexdigest(),)).fetchone()
        assert row
        account = row[0]
    assert re.fullmatch(r'[0-9a-f]{32}', account)
    print('自动建立设备凭证：通过', flush=True)
    assert json.loads(expect('GET', '/api/people')) == []
    person = json.loads(expect('GET', '/api/current-person'))['id']
    expect('PUT', '/api/people/' + person, {'name':'测试讲述者','background':'用于验证的虚构资料'})
    data = io.BytesIO()
    with wave.open(data, 'wb') as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000); w.writeframes(b'\0\0' * 16000)
    audio = base64.b64encode(data.getvalue()).decode()
    async def test_voice():
        async with websockets.connect('wss://onesay.top/lifepages/api/voice/stream', additional_headers={'Authorization':'Bearer ' + token}, open_timeout=20) as ws:
            event = json.loads(await asyncio.wait_for(ws.recv(), 25))
            if event.get('type') != 'ready': raise RuntimeError('语音握手失败')
            await ws.send(b'\0\0' * 16000)
            await ws.send(json.dumps({'type':'finish'}))
            while True:
                event = json.loads(await asyncio.wait_for(ws.recv(), 35))
                if event.get('type') == 'error': raise RuntimeError('语音识别失败')
                if event.get('type') == 'final': break
    asyncio.run(test_voice())
    print('实时语音中转（静音样本）：通过', flush=True)
    body = {'request_id': uuid.uuid4().hex, 'text':'我小时候住在海边。', 'audio_base64':audio}
    turn = json.loads(expect('POST', f'/api/people/{person}/turns', body))
    retry = json.loads(expect('POST', f'/api/people/{person}/turns', body))
    assert turn == retry and turn['text'].strip()
    answer = turn['user_id']
    chapter = json.loads(expect('POST', f'/api/people/{person}/chapters/generate'))['id']
    print('大模型追问和章节生成：通过', flush=True)
    url = json.loads(expect('POST', f'/api/chapters/{chapter}/share'))['url']
    assert url.startswith(BASE + '/listen/')
    share_token = url.rsplit('/',1)[1]
    page = expect('GET', '/listen/' + share_token, authenticated=False).decode()
    assert url + '/audio/' + answer in page
    expect('GET', '/listen/' + share_token + '/audio/' + answer, authenticated=False)
    expect('DELETE', f'/api/chapters/{chapter}/shares')
    expect('GET', '/listen/' + share_token, expected=404, authenticated=False)
    print('原声播放地址与撤销：通过', flush=True)
finally:
    if account and re.fullmatch(r'[0-9a-f]{32}', account):
        with sqlite3.connect(REGISTRY) as conn:
            conn.execute('DELETE FROM share_lookup WHERE account_id=?', (account,))
            conn.execute('DELETE FROM accounts WHERE id=?', (account,))
        shutil.rmtree(os.path.join(ACCOUNTS, account), ignore_errors=True)
        print('已清理本次临时测试数据', flush=True)
