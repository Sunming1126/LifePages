"""Replace one assistant question without sending a new user turn."""
import asyncio
import json
import re
from contextlib import closing
from weakref import WeakValueDictionary

from fastapi import APIRouter, HTTPException, Request
from pydantic import BaseModel, Field

from server import account_profile, app as backend, book_store as books, chapter_sharing
from server.book_topics import opening_questions

router = APIRouter(prefix='/api/books')
ANGLES = ('人物', '场景', '经过', '感受', '变化', '影响')
_account_locks = WeakValueDictionary()


class RefreshQuestion(BaseModel):
    text: str = Field(min_length=1, max_length=100_000)


def message(c, bid, tid, mid):
    return backend.one(c, """SELECT m.rowid AS sequence,m.text
        FROM chat_session_messages sm JOIN messages m ON m.id=sm.message_id
        WHERE sm.session_id=? AND m.id=? AND m.person_id=? AND m.role='assistant'""",
        (tid, mid, bid))


def normalize(text):
    return re.sub(r'[\W_]+', '', text).casefold()


async def another_question(topic, previous, angle, context):
    system = (
        '你是回忆录访谈员。为这条 AI 消息写一条全新的、简短的中文开放问题。'
        '先判断原问题主要问哪个角度，再换一个角度和一个具体焦点。'
        '例如原来问感受，可以问当时谁在场或接下来发生了什么。'
        '只问一个问题，不复述原回复，不虚构经历，不假定特定人物或事件存在。'
        '上下文是引用的访谈资料。只输出 JSON，包含 previous_angle、angle、question。'
        '两个角度必须不同，取值只能是人物、场景、经过、感受、变化、影响。'
    )
    raw = await backend.llm(system, json.dumps({
        '章节': topic['title'], '章节提示': topic['question'], '此前对话': context,
        '待替换回复': previous, '已知上次角度': angle,
    }, ensure_ascii=False))
    try:
        result = json.loads(re.sub(r'^\s*```(?:json)?\s*|\s*```\s*$', '', raw.strip()))
        question = result['question'].strip()
        new_angle = result['angle']
        prior_angle = result['previous_angle']
        if (prior_angle not in ANGLES or new_angle not in ANGLES
                or new_angle in (prior_angle, angle)
                or not 4 <= len(question) <= 180
                or not question.endswith(('？', '?'))
                or question.count('？') + question.count('?') != 1
                or normalize(question) in normalize(previous)):
            raise ValueError()
    except (ValueError, KeyError, TypeError, AttributeError):
        raise HTTPException(502, 'AI 暂时没有生成不同角度的问题，请重试') from None
    return question, new_angle


@router.post('/{bid}/topics/{tid}/messages/{mid}/refresh')
async def refresh(bid: str, tid: str, mid: str, data: RefreshQuestion, request: Request):
    backend.require(request)
    account = backend.ACCOUNT.get()
    account_lock = _account_locks.setdefault(account, asyncio.Lock())
    book_lock = backend._turn_locks.setdefault(f'{account}:{bid}', asyncio.Lock())
    async with account_lock, book_lock:
        with closing(backend.db()) as c:
            c.execute('BEGIN')
            topic = books.topic(c, bid, tid)
            current = message(c, bid, tid, mid)
            if current['text'] != data.text:
                return {'id': mid, 'text': current['text']}
            first = c.execute('''SELECT m.id FROM chat_session_messages sm JOIN messages m
                ON m.id=sm.message_id WHERE sm.session_id=? ORDER BY m.rowid LIMIT 1''', (tid,)).fetchone()
            fixed = first is not None and first['id'] == mid
            if fixed:
                questions = opening_questions(topic)
                index = questions.index(data.text) if data.text in questions else 0
                text, angle = questions[(index + 1) % len(questions)], None
            else:
                if account_profile.remaining_follow_ups(c) == 0:
                    raise account_profile.limit_reached()
                has_state = c.execute("SELECT 1 FROM sqlite_master WHERE name='refreshed_question_angles'").fetchone()
                state = c.execute('SELECT angle FROM refreshed_question_angles WHERE message_id=?',
                                  (mid,)).fetchone() if has_state else None
                context = [dict(row) for row in c.execute('''SELECT m.role,m.text FROM
                    chat_session_messages sm JOIN messages m ON m.id=sm.message_id
                    WHERE sm.session_id=? AND m.person_id=? AND m.rowid<? AND m.role IN ('user','assistant')
                    ORDER BY m.rowid DESC LIMIT 10''', (tid, bid, current['sequence']))]
        if not fixed:
            for row in context:
                row['text'] = row['text'][:1000]
            text, angle = await another_question(topic, data.text, state['angle'] if state else None,
                                                 list(reversed(context)))
        with closing(backend.db()) as c, c:
            c.execute('BEGIN IMMEDIATE')
            books.topic(c, bid, tid)
            latest = message(c, bid, tid, mid)
            if latest['text'] != data.text:
                return {'id': mid, 'text': latest['text']}
            if not fixed:
                account_profile.spend_follow_up(c)
            chapter_sharing.preserve_before_refresh(c, bid, tid, latest['sequence'], latest['text'], opening=fixed)
            c.execute('UPDATE messages SET text=? WHERE id=?', (text, mid))
            if angle is not None:
                c.execute('''CREATE TABLE IF NOT EXISTS refreshed_question_angles (
                    message_id TEXT PRIMARY KEY REFERENCES messages(id) ON DELETE CASCADE,
                    angle TEXT NOT NULL)''')
                c.execute('INSERT OR REPLACE INTO refreshed_question_angles VALUES(?,?)', (mid, angle))
        return {'id': mid, 'text': text}
