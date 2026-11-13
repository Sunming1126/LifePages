"""Synthetic direct-speech smoke test; prints no credentials."""
import asyncio, hashlib, json, shutil, sqlite3, urllib.request
import websockets
BASE='https://onesay.top/lifepages'
registry='/opt/lifepages/shared/data/registry.sqlite3'
token=None; account=None

def call(path, payload=None):
    req=urllib.request.Request(BASE+path, data=json.dumps(payload or {}).encode(), headers={'Content-Type':'application/json', **({'Authorization':'Bearer '+token} if token else {})}, method='POST')
    with urllib.request.urlopen(req, timeout=30) as r: return json.loads(r.read())

try:
    token=call('/api/bootstrap')['token']
    with sqlite3.connect(registry) as c: account=c.execute('SELECT id FROM accounts WHERE token_hash=?',(hashlib.sha256(token.encode()).hexdigest(),)).fetchone()[0]
    credential=call('/api/voice/token')
    assert credential['token'].startswith('st-')
    async def voice():
        async with websockets.connect('wss://dashscope.aliyuncs.com/api-ws/v1/inference/', additional_headers={'Authorization':'Bearer '+credential['token']}, open_timeout=15) as ws:
            task='0'*32
            await ws.send(json.dumps({'header':{'action':'run-task','task_id':task,'streaming':'duplex'},'payload':{'task_group':'audio','task':'asr','function':'recognition','model':'fun-asr-realtime','parameters':{'sample_rate':16000,'format':'pcm'},'input':{}}}))
            r=json.loads(await asyncio.wait_for(ws.recv(),20)); assert r['header']['event']=='task-started'
            for _ in range(10):
                await ws.send(b'\0\0'*1600); await asyncio.sleep(.1)
            await ws.send(json.dumps({'header':{'action':'finish-task','task_id':task,'streaming':'duplex'},'payload':{'input':{}}}))
            while True:
                r=json.loads(await asyncio.wait_for(ws.recv(),15))
                if r['header']['event']=='task-failed': raise RuntimeError('direct recognition failed')
                if r['header']['event']=='task-finished': break
    asyncio.run(voice())
    print('短时凭证签发及直连 Fun-ASR（静音样本）：通过')
finally:
    if account:
        with sqlite3.connect(registry) as c:
            c.execute('DELETE FROM accounts WHERE id=?',(account,))
        shutil.rmtree('/opt/lifepages/shared/data/accounts/'+account,ignore_errors=True)
        print('临时测试数据已清理')
