"""Read-only sidecar that streams saved LifePages replies into RTC rooms."""

import asyncio
import os
import re
import sqlite3
import time
from contextlib import asynccontextmanager, closing, suppress
from dataclasses import dataclass, field
from pathlib import Path
from uuid import uuid4

import httpx
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

from server import book_store, rtc_gateway
from server.account_access import bearer_digest, resolve_account

DATA = Path(os.getenv('LIFEPAGES_DATA', '/opt/lifepages/shared/data'))
ID = r'^[0-9a-f]{32}$'
ROOM_SECONDS = 180
# The current private speech resource delivered ten simultaneous audio streams.
MAX_ROOMS = 10
# Each provider command accepts up to 200 characters ending in punctuation.
SENTENCE_END = '。！？.!?；;'


def speech_segments(text: str) -> list[str]:
    rest = ' '.join(text.split())
    segments = []
    while rest:
        if len(rest) <= 199:
            part, rest = rest, ''
        else:
            end = max(rest.rfind(mark, 0, 199) for mark in SENTENCE_END) + 1
            end = end if end >= 80 else 199
            part, rest = rest[:end].rstrip(), rest[end:].lstrip()
        segments.append(part if part[-1] in SENTENCE_END else part + '。')
    return segments


def readonly(path: Path):
    return closing(sqlite3.connect(path.as_uri() + '?mode=ro', uri=True, timeout=0.25))


def account_session(header):
    digest = bearer_digest(header)
    if digest:
        with readonly(DATA / 'registry.sqlite3') as conn:
            owner = resolve_account(conn, digest)
        if owner and re.fullmatch(ID, owner):
            return owner, digest
    raise HTTPException(401, '需要有效的设备凭证')


def check_book(owner, book_id):
    with readonly(DATA / 'accounts' / owner / 'lifepages.sqlite3') as conn:
        book_store.active(conn, book_id)
        if conn.execute('SELECT 1 FROM people WHERE id=?', (book_id,)).fetchone() is None:
            raise HTTPException(404, '找不到回忆录')


def reply_text(owner: str, message_id: str) -> str:
    with readonly(DATA / 'accounts' / owner / 'lifepages.sqlite3') as conn:
        reply = conn.execute(
            "SELECT person_id, text FROM messages WHERE id=? AND role='assistant'", (message_id,),
        ).fetchone()
        if reply:
            book_store.active(conn, reply[0])
            return reply[1]
    raise HTTPException(404, '找不到可播报的回复')


class Bootstrap(BaseModel):
    message_id: str = Field(pattern=ID)
    voice_id: str | None = None


class TurnBootstrap(BaseModel):
    request_id: str = Field(pattern=ID)
    book_id: str = Field(pattern=ID)
    voice_id: str | None = None


class Speak(BaseModel):
    segment: int = Field(ge=0)


@dataclass
class Playback:
    owner: str
    credential: str
    message_id: str
    segments: list[str]
    speaker: str
    book_id: str | None = None
    room: str = field(default_factory=lambda: 'lifepages_' + uuid4().hex)
    user: str = field(default_factory=lambda: 'listener_' + uuid4().hex)
    bot: str = field(default_factory=lambda: 'reader_' + uuid4().hex)
    task: str = field(default_factory=lambda: uuid4().hex)
    expires: int = field(default_factory=lambda: int(time.time()) + ROOM_SECONDS)
    lock: asyncio.Lock = field(default_factory=asyncio.Lock)
    attempted: bool = False
    closing: bool = False
    next_segment: int = 0

    @property
    def target(self):
        return {'RoomId': self.room, 'TaskId': self.task}


async def stop(client, rooms, session_id, playback):
    playback.closing = True
    async with playback.lock:
        if rooms.get(session_id) is not playback:
            return
        if playback.attempted:
            try:
                await rtc_gateway.call(client, 'StopVoiceChat', playback.target)
            except rtc_gateway.RtcError:
                # Retry during cleanup. Volcengine ends tasks after the listener has left.
                if time.time() < playback.expires + ROOM_SECONDS:
                    return
        rooms.pop(session_id, None)


async def sweep(client, rooms):
    while True:
        await asyncio.sleep(10)
        candidates = tuple(rooms.items())
        if candidates:
            invalid = await asyncio.to_thread(revoked_rooms, candidates)
            await asyncio.gather(*(
                stop(client, rooms, sid, playback)
                for sid, playback in candidates
                if playback.closing or time.time() >= playback.expires or sid in invalid
            ))


def revoked_rooms(candidates):
    try:
        with readonly(DATA / 'registry.sqlite3') as conn:
            return {sid for sid, room in candidates
                    if resolve_account(conn, room.credential) != room.owner}
    except sqlite3.Error:
        # Recheck on the next sweep if a concurrent registry write holds the DB.
        return set()


@asynccontextmanager
async def lifespan(app):
    rooms = app.state.rooms = {}
    async with httpx.AsyncClient(timeout=8, trust_env=False) as client:
        app.state.client = client
        cleanup = asyncio.create_task(sweep(client, rooms))
        try:
            yield
        finally:
            cleanup.cancel()
            with suppress(asyncio.CancelledError):
                await cleanup
            await asyncio.gather(*(
                stop(client, rooms, sid, playback)
                for sid, playback in tuple(rooms.items())
            ))


app = FastAPI(lifespan=lifespan, docs_url=None, redoc_url=None, openapi_url=None)


@app.middleware('http')
async def no_cache(request, call_next):
    try:
        response = await call_next(request)
    except sqlite3.Error:
        response = JSONResponse({'detail': '暂时无法读取回复'}, status_code=503)
    response.headers['Cache-Control'] = 'no-store'
    return response


@app.get('/health')
async def health():
    return {'rtcConfigured': rtc_gateway.configured()}


@app.post('/api/rtc/sessions')
async def bootstrap(body: Bootstrap, request: Request):
    owner, credential = await asyncio.to_thread(account_session, request.headers.get('authorization'))
    segments = speech_segments(await asyncio.to_thread(reply_text, owner, body.message_id))
    if not segments:
        raise HTTPException(404, '找不到可播报的回复')
    return reserve(owner, credential, body.message_id, segments, voice_id=body.voice_id)


@app.post('/api/rtc/turns')
async def bootstrap_turn(body: TurnBootstrap, request: Request):
    owner, credential = await asyncio.to_thread(account_session, request.headers.get('authorization'))
    await asyncio.to_thread(check_book, owner, body.book_id)
    return reserve(owner, credential, body.request_id, [], body.book_id, voice_id=body.voice_id)


def reserve(owner, credential, message_id, segments, book_id=None, *, voice_id=None):
    if not rtc_gateway.configured():
        raise HTTPException(503, '语音播报暂未配置')
    speaker = rtc_gateway.default_speaker() if voice_id is None else rtc_gateway.VOICE_PRESETS.get(voice_id)
    if not speaker:
        raise HTTPException(422, '不支持此播报音色')
    rooms = app.state.rooms
    for existing_id, existing in rooms.items():
        if existing.owner == owner:
            if (existing.credential == credential and not existing.closing and not existing.attempted
                    and existing.message_id == message_id
                    and existing.book_id == book_id and existing.speaker == speaker
                    and time.time() < existing.expires):
                return credentials(existing_id, existing)
            raise HTTPException(429, '上一次播报正在结束')
    if len(rooms) >= MAX_ROOMS:
        raise HTTPException(429, '语音播报繁忙')
    session_id = uuid4().hex
    playback = Playback(owner, credential, message_id, segments, speaker, book_id)
    result = credentials(session_id, playback)
    rooms[session_id] = playback
    return result


def credentials(session_id, playback):
    return {
        'sessionId': session_id, 'appId': os.environ['VOLC_RTC_APP_ID'].strip(),
        'roomId': playback.room, 'userId': playback.user,
        'botUserId': playback.bot, 'taskId': playback.task,
        'token': rtc_gateway.issue_token(playback.room, playback.user, playback.expires),
        'segments': len(playback.segments),
    }


async def owned_room(request, session_id):
    owner, credential = await asyncio.to_thread(account_session, request.headers.get('authorization'))
    playback = app.state.rooms.get(session_id)
    return playback if playback and (playback.owner, playback.credential) == (owner, credential) else None


def turn_segment(playback, index):
    with readonly(DATA / 'accounts' / playback.owner / 'lifepages.sqlite3') as conn:
        book_store.active(conn, playback.book_id)
        exists = conn.execute("SELECT 1 FROM sqlite_master WHERE name='rtc_turn_segments'").fetchone()
        segment = exists and conn.execute('''SELECT s.text FROM rtc_turn_segments s
            JOIN chat_turns t ON s.request_id=t.request_id
            WHERE s.request_id=? AND t.person_id=? AND s.segment=? AND s.created>=?''',
            (playback.message_id, playback.book_id, index, int(time.time()) - ROOM_SECONDS)).fetchone()
    if not segment:
        raise HTTPException(409, '播报段落还未生成')
    text = segment[0].rstrip('，,、') or segment[0]
    return text if text[-1] in SENTENCE_END else text + '。'


async def start_agent(playback):
    if playback.closing or time.time() >= playback.expires:
        raise HTTPException(404, '播报会话已结束')
    if playback.attempted:
        return
    playback.attempted = True
    try:
        await rtc_gateway.call(app.state.client, 'StartVoiceChat', {
            **playback.target, **rtc_gateway.agent_config(playback.user, playback.bot, playback.speaker),
        })
    except rtc_gateway.RtcError:
        playback.closing = True
        raise HTTPException(502, '语音播报暂时不可用') from None


@app.post('/api/rtc/sessions/{session_id}/start')
async def start_turn(session_id: str, request: Request):
    playback = await owned_room(request, session_id)
    if playback is None or playback.book_id is None:
        raise HTTPException(404, '播报会话已结束')
    async with playback.lock:
        await start_agent(playback)
    return {'started': True}


@app.post('/api/rtc/sessions/{session_id}/speak')
async def speak(session_id: str, body: Speak, request: Request):
    playback = await owned_room(request, session_id)
    if playback is None:
        raise HTTPException(404, '播报会话已结束')
    async with playback.lock:
        if playback.closing or time.time() >= playback.expires:
            raise HTTPException(404, '播报会话已结束')
        index = body.segment
        if index < playback.next_segment:
            return {'accepted': True}
        if index != playback.next_segment:
            raise HTTPException(409, '播报段落顺序错误')
        if playback.book_id:
            text = await asyncio.to_thread(turn_segment, playback, index)
        else:
            if index >= len(playback.segments):
                raise HTTPException(409, '播报段落顺序错误')
            # Recheck book availability before sending a saved reply off-server.
            await asyncio.to_thread(reply_text, playback.owner, playback.message_id)
            text = playback.segments[index]
        client = app.state.client
        try:
            await start_agent(playback)
            if playback.closing:
                raise HTTPException(404, '播报会话已结束')
            await rtc_gateway.call(client, 'UpdateVoiceChat', {
                **playback.target, 'Command': 'ExternalTextToSpeech',
                'Message': text, 'InterruptMode': 2,
            })
        except rtc_gateway.RtcError:
            playback.closing = True
            raise HTTPException(502, '语音播报暂时不可用') from None
        playback.next_segment += 1
        return {'accepted': True}


@app.delete('/api/rtc/sessions/{session_id}')
async def close(session_id: str, request: Request):
    playback = await owned_room(request, session_id)
    if playback is not None:
        await stop(app.state.client, app.state.rooms, session_id, playback)
    return {'closed': True}
