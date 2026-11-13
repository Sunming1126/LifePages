"""Verify the lightweight overview with synthetic data and clean it up."""
import hashlib,json,sqlite3,shutil,urllib.request
BASE='https://onesay.top/lifepages'
token=None;account=None

def call(method,path,body=None):
    headers={'Content-Type':'application/json'}
    if token:headers['Authorization']='Bearer '+token
    request=urllib.request.Request(BASE+path,data=json.dumps(body).encode() if body is not None else None,headers=headers,method=method)
    with urllib.request.urlopen(request,timeout=25) as response:
        raw=response.read()
        return json.loads(raw),len(raw)

try:
    token=call('POST','/api/bootstrap',{})[0]['token']
    with sqlite3.connect('/opt/lifepages/shared/data/registry.sqlite3') as c:
        account=c.execute('SELECT id FROM accounts WHERE token_hash=?',(hashlib.sha256(token.encode()).hexdigest(),)).fetchone()[0]
    person=call('GET','/api/current-person')[0]['id']
    call('POST',f'/api/people/{person}/answers',{'text':'仅用于接口测试的虚构资料。'*1000})
    result,size=call('GET',f'/api/people/{person}/memoir')
    _,old_size=call('GET',f'/api/people/{person}')
    assert result['stats']=={'stories':1,'recordings':0,'chapters':0}
    assert 'messages' not in result and size<old_size/5
    print('线上轻量概览、记录数量及不返回聊天正文：通过')
finally:
    if account:
        with sqlite3.connect('/opt/lifepages/shared/data/registry.sqlite3') as c:c.execute('DELETE FROM accounts WHERE id=?',(account,))
        shutil.rmtree('/opt/lifepages/shared/data/accounts/'+account,ignore_errors=True)
        print('本次临时测试数据已清理')
