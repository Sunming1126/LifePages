import os, sqlite3, uuid, io, json
from pathlib import Path
from fastapi import FastAPI, UploadFile, File, Form, HTTPException
from fastapi.responses import FileResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel
import httpx, qrcode

ROOT = Path(__file__).resolve().parent
# Local configuration stays outside version control; explicit environment values win.
local_config = ROOT / '.env'
if local_config.exists():
    for line in local_config.read_text(encoding='utf-8-sig').splitlines():
        if line.strip() and not line.lstrip().startswith('#') and '=' in line:
            key, value = line.split('=', 1)
            os.environ.setdefault(key.strip(), value.strip())
DATA = ROOT / 'data'; AUDIO = DATA / 'audio'; AUDIO.mkdir(parents=True, exist_ok=True)
app = FastAPI(title='LifePages')
app.mount('/static', StaticFiles(directory=ROOT / 'static'), name='static')

def db():
    c = sqlite3.connect(DATA / 'life.db'); c.row_factory = sqlite3.Row; return c
with db() as c:
    c.executescript('''CREATE TABLE IF NOT EXISTS project(id INTEGER PRIMARY KEY, name TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS stories(id INTEGER PRIMARY KEY, project_id INTEGER NOT NULL, title TEXT NOT NULL, content TEXT NOT NULL DEFAULT '', question TEXT NOT NULL DEFAULT '');
    CREATE TABLE IF NOT EXISTS recordings(id INTEGER PRIMARY KEY, story_id INTEGER NOT NULL, filename TEXT NOT NULL, transcript TEXT NOT NULL DEFAULT '', question TEXT NOT NULL DEFAULT '', created TEXT DEFAULT CURRENT_TIMESTAMP);''')
class Project(BaseModel): name: str
class Story(BaseModel): project_id: int; title: str; question: str = ''
class Edit(BaseModel): title: str; content: str
class Transcript(BaseModel): transcript: str
class Question(BaseModel): question: str
class AIRequest(BaseModel): story_id: int; mode: str

def rows(query, params=()):
    with db() as c: return [dict(x) for x in c.execute(query, params).fetchall()]
def need_story(i):
    result = rows('SELECT * FROM stories WHERE id=?', (i,))
    if not result: raise HTTPException(404, '故事不存在')
    return result[0]
@app.get('/')
def index(): return FileResponse(ROOT / 'static' / 'index.html')
@app.get('/listen/{story_id}')
def listen(story_id: int):
    need_story(story_id); return FileResponse(ROOT / 'static' / 'listen.html')
@app.get('/api/config')
def config(): return {'ai': bool(os.getenv('OPENAI_API_KEY')), 'transcription': bool(os.getenv('TRANSCRIBE_API_KEY') and os.getenv('TRANSCRIBE_BASE_URL')), 'base_url': os.getenv('BASE_URL', 'http://127.0.0.1:8000')}
@app.get('/api/projects')
def projects(): return rows('SELECT * FROM project ORDER BY id DESC')
@app.post('/api/projects')
def create_project(p: Project):
    name = p.name.strip()
    if not name: raise HTTPException(400, '请输入称呼')
    with db() as c:
        cur = c.execute('INSERT INTO project(name) VALUES (?)', (name,)); return {'id': cur.lastrowid, 'name': name}
@app.get('/api/projects/{pid}/stories')
def stories(pid: int): return rows('SELECT * FROM stories WHERE project_id=? ORDER BY id', (pid,))
@app.post('/api/stories')
def create_story(s: Story):
    if not rows('SELECT id FROM project WHERE id=?', (s.project_id,)): raise HTTPException(404, '项目不存在')
    if not s.title.strip(): raise HTTPException(400, '请输入故事标题')
    with db() as c:
        cur = c.execute('INSERT INTO stories(project_id,title,question) VALUES(?,?,?)', (s.project_id,s.title.strip(),s.question)); return {'id': cur.lastrowid}
@app.get('/api/stories/{sid}')
def story(sid: int):
    s=need_story(sid); s['recordings']=rows('SELECT id,transcript,question,created FROM recordings WHERE story_id=? ORDER BY id',(sid,)); return s
@app.put('/api/stories/{sid}')
def edit_story(sid: int, e: Edit):
    need_story(sid)
    with db() as c: c.execute('UPDATE stories SET title=?,content=? WHERE id=?', (e.title,e.content,sid))
    return {'ok':True}
@app.put('/api/stories/{sid}/question')
def save_question(sid: int, q: Question):
    need_story(sid)
    with db() as c: c.execute('UPDATE stories SET question=? WHERE id=?', (q.question,sid))
    return {'ok':True}
@app.post('/api/stories/{sid}/recordings')
async def recording(sid: int, audio: UploadFile=File(...), question: str=Form('')):
    need_story(sid); content=await audio.read()
    if not content or len(content)>50*1024*1024: raise HTTPException(400,'录音为空或超过50MB')
    ext = '.mp4' if audio.content_type and 'mp4' in audio.content_type else '.ogg' if audio.content_type and 'ogg' in audio.content_type else '.webm'
    filename=uuid.uuid4().hex+ext; (AUDIO/filename).write_bytes(content)
    with db() as c:
        cur=c.execute('INSERT INTO recordings(story_id,filename,question) VALUES(?,?,?)',(sid,filename,question)); return {'id':cur.lastrowid}
@app.get('/api/recordings/{rid}/audio')
def audio_file(rid: int):
    r=rows('SELECT filename FROM recordings WHERE id=?',(rid,))
    if not r: raise HTTPException(404,'录音不存在')
    return FileResponse(AUDIO / r[0]['filename'])
@app.put('/api/recordings/{rid}')
def edit_transcript(rid: int, t: Transcript):
    with db() as c:
        cur=c.execute('UPDATE recordings SET transcript=? WHERE id=?',(t.transcript,rid))
        if not cur.rowcount: raise HTTPException(404,'录音不存在')
    return {'ok':True}
def api_config():
    key=os.getenv('OPENAI_API_KEY')
    if not key: raise HTTPException(400,'未配置 AI 服务，请先设置 OPENAI_API_KEY')
    return os.getenv('OPENAI_BASE_URL','https://api.openai.com/v1').rstrip('/'), {'Authorization':'Bearer '+key}
@app.post('/api/recordings/{rid}/transcribe')
async def transcribe(rid: int):
    r=rows('SELECT filename FROM recordings WHERE id=?',(rid,))
    if not r: raise HTTPException(404,'录音不存在')
    stt_key=os.getenv('TRANSCRIBE_API_KEY'); base=os.getenv('TRANSCRIBE_BASE_URL', '').rstrip('/')
    if not stt_key or not base: raise HTTPException(400,'????????????????????')
    headers={'Authorization':'Bearer '+stt_key}; path=AUDIO/r[0]['filename']
    try:
        async with httpx.AsyncClient(timeout=120) as client:
            with path.open('rb') as f: response=await client.post(base+'/audio/transcriptions',headers=headers,files={'file':(path.name,f,{'.mp4':'audio/mp4','.ogg':'audio/ogg'}.get(path.suffix,'audio/webm'))},data={'model':os.getenv('TRANSCRIBE_MODEL','whisper-1')})
        response.raise_for_status(); text=response.json()['text']
    except Exception: raise HTTPException(502,'转写服务调用失败，请检查服务配置；也可手动填写文字')
    edit_transcript(rid,Transcript(transcript=text)); return {'text':text}
@app.post('/api/ai')
async def ai(req: AIRequest):
    story=need_story(req.story_id); recs=rows('SELECT question, transcript FROM recordings WHERE story_id=? ORDER BY id',(req.story_id,))
    text='\n'.join('问题：'+r['question']+'\n回答：'+r['transcript'] for r in recs if r['transcript'].strip())
    if not text: raise HTTPException(400,'请先填写或转写至少一段回答')
    if req.mode not in ('followup','draft'): raise HTTPException(400,'无效模式')
    prompt=('你是一位温柔的口述史访谈员。根据回答只提出一个具体而自然的追问，不假设未说过的事实。只输出问题。' if req.mode=='followup' else '根据口述整理成第一人称回忆录片段，保留说话者的表达，不编造事实、心理或对话，缺失信息不补写。只输出正文。')
    # UTF-8 byte count is a conservative upper bound for the token budget.
    if len(text.encode('utf-8')) > 900000:
        raise HTTPException(400,'??????????????????????')
    base,headers=api_config()
    try:
        async with httpx.AsyncClient(timeout=120) as client:
            response=await client.post(base+'/chat/completions',headers=headers,json={'model':os.getenv('CHAT_MODEL','deepseek-v4.1-flash'),'max_tokens':4096,'messages':[{'role':'system','content':prompt},{'role':'user','content':text}]})
        response.raise_for_status(); return {'text':response.json()['choices'][0]['message']['content']}
    except Exception: raise HTTPException(502,'AI服务调用失败，请检查服务地址、模型和密钥')
@app.get('/api/stories/{sid}/qr')
def qr(sid: int):
    need_story(sid); base=os.getenv('BASE_URL','http://127.0.0.1:8000').rstrip('/'); img=qrcode.make(base+'/listen/'+str(sid)); out=io.BytesIO(); img.save(out,format='PNG'); out.seek(0); return StreamingResponse(out,media_type='image/png')
