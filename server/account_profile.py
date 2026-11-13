"""Account profile and free AI follow-up allowance."""
import base64
from contextlib import closing
from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, HTTPException, Request
from pydantic import BaseModel, Field, StrictBool

from server import app as backend

router = APIRouter(prefix='/api/profile')
FREE_FOLLOW_UPS = 3
BEIJING = timezone(timedelta(hours=8))


class ProfilePatch(BaseModel):
    display_name: str | None = Field(default=None, max_length=30)
    avatar: str | None = Field(default=None, max_length=700_000)


class BackgroundAI(BaseModel):
    enabled: StrictBool


def background_ai(c):
    if not has_table(c, 'ai_privacy'):
        return False
    row = c.execute('SELECT enabled FROM ai_privacy WHERE id=1').fetchone()
    return bool(row and row[0])


@router.get('/background-ai')
def get_background_ai(request: Request):
    backend.require(request)
    with closing(backend.db()) as c:
        return {'enabled': background_ai(c)}


@router.put('/background-ai')
def set_background_ai(data: BackgroundAI, request: Request):
    backend.require(request)
    with closing(backend.db()) as c, c:
        c.execute('''CREATE TABLE IF NOT EXISTS ai_privacy (
            id INTEGER PRIMARY KEY CHECK(id=1), enabled INTEGER NOT NULL)''')
        c.execute('''INSERT INTO ai_privacy VALUES(1,?)
            ON CONFLICT(id) DO UPDATE SET enabled=excluded.enabled''', (data.enabled,))
    return {'enabled': data.enabled}


def day_key():
    return datetime.now(BEIJING).date().isoformat()


def has_table(c, name):
    return c.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (name,)).fetchone()


def remaining_follow_ups(c):
    row = None
    if has_table(c, 'daily_follow_ups'):
        row = c.execute('SELECT used FROM daily_follow_ups WHERE id=1 AND day=?', (day_key(),)).fetchone()
    return max(0, FREE_FOLLOW_UPS - row['used']) if row else FREE_FOLLOW_UPS


def limit_reached():
    return HTTPException(429, '今日的 3 次 AI 追问已用完')


def spend_follow_up(c):
    c.execute('''CREATE TABLE IF NOT EXISTS daily_follow_ups (
        id INTEGER PRIMARY KEY CHECK (id=1), day TEXT NOT NULL, used INTEGER NOT NULL)''')
    cursor = c.execute('''INSERT INTO daily_follow_ups VALUES(1,?,1)
        ON CONFLICT(id) DO UPDATE SET day=excluded.day,
            used=CASE WHEN daily_follow_ups.day=excluded.day THEN daily_follow_ups.used+1 ELSE 1 END
        WHERE daily_follow_ups.day<>excluded.day OR daily_follow_ups.used<?''', (day_key(), FREE_FOLLOW_UPS))
    if cursor.rowcount != 1:
        raise limit_reached()


def profile(c):
    row = None
    if has_table(c, 'account_profile'):
        row = c.execute('SELECT display_name,avatar FROM account_profile WHERE id=1').fetchone()
    return {'display_name': row['display_name'] if row else '',
            'avatar': base64.b64encode(row['avatar']).decode() if row and row['avatar'] else None,
            'follow_ups': {'limit': FREE_FOLLOW_UPS, 'remaining': remaining_follow_ups(c)}}


@router.get('')
def get_profile(request: Request):
    backend.require(request)
    with closing(backend.db()) as c:
        c.execute('BEGIN')
        return profile(c)


@router.patch('')
def edit_profile(data: ProfilePatch, request: Request):
    backend.require(request)
    avatar = None
    if data.avatar is not None:
        try:
            avatar = base64.b64decode(data.avatar, validate=True)
        except ValueError:
            raise HTTPException(400, '头像图片无效') from None
        if not (4 < len(avatar) <= 512 * 1024 and avatar.startswith(b'\xff\xd8\xff')
                and avatar.endswith(b'\xff\xd9')):
            raise HTTPException(400, '请选择不超过 512 KB 的 JPEG 图片')
    with closing(backend.db()) as c, c:
        c.execute('BEGIN IMMEDIATE')
        c.execute('''CREATE TABLE IF NOT EXISTS account_profile (
            id INTEGER PRIMARY KEY CHECK (id=1), display_name TEXT NOT NULL, avatar BLOB)''')
        c.execute("INSERT OR IGNORE INTO account_profile VALUES(1,'',NULL)")
        if 'display_name' in data.model_fields_set:
            c.execute('UPDATE account_profile SET display_name=? WHERE id=1', ((data.display_name or '').strip(),))
        if 'avatar' in data.model_fields_set:
            c.execute('UPDATE account_profile SET avatar=? WHERE id=1', (avatar,))
        return profile(c)
