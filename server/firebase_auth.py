"""Verify Firebase social sign-ins and exchange them for LifePages sessions."""
import base64
import binascii
import json
import os
from contextlib import closing
from dataclasses import dataclass

import httpx
from fastapi import APIRouter, HTTPException, Request
from pydantic import BaseModel, Field

from server import app as backend, email_auth

router = APIRouter(prefix='/api/auth')
SCHEMA = """
CREATE TABLE IF NOT EXISTS firebase_identities (
    project_id TEXT NOT NULL,
    provider TEXT NOT NULL,
    subject TEXT NOT NULL,
    account_id TEXT NOT NULL REFERENCES accounts(id),
    PRIMARY KEY (project_id, provider, subject)
);
CREATE INDEX IF NOT EXISTS firebase_identities_account ON firebase_identities(account_id);
"""
PROVIDERS = {'apple.com': 'Apple', 'google.com': 'Google'}
LOOKUP_URL = 'https://identitytoolkit.googleapis.com/v1/accounts:lookup'


class FirebaseLogin(BaseModel):
    id_token: str = Field(min_length=20, max_length=16_384)
    link: bool = False


@dataclass(frozen=True)
class Identity:
    project: str
    provider: str
    subject: str
    email: str | None


def invalid_token():
    return HTTPException(401, '登录凭证无效或已过期，请重新授权')


def settings():
    project = os.getenv('LIFEPAGES_FIREBASE_PROJECT_ID', '')
    key = os.getenv('LIFEPAGES_FIREBASE_API_KEY', '')
    if not project and not key:
        try:
            config = json.loads((backend.ROOT / 'config' / 'firebase_auth.json').read_text())
            project, key = config['project_id'], config['api_key']
        except (OSError, ValueError, KeyError, TypeError):
            pass
    if not project or not key:
        raise HTTPException(503, 'Apple 和 Google 登录暂不可用')
    return project, key


async def verify_token(token: str):
    project, key = settings()
    # Read the untrusted claims only to reject malformed and cross-project input.
    # Identity Platform validates the same signed token before we use any claims.
    try:
        _, encoded, _ = token.split('.')
        claims = json.loads(base64.urlsafe_b64decode(encoded + '=' * (-len(encoded) % 4)))
        provider = claims['firebase']['sign_in_provider']
        uid = claims['sub']
        if (claims['aud'] != project or claims['iss'] != f'https://securetoken.google.com/{project}'
                or provider not in PROVIDERS or not isinstance(uid, str) or not 1 <= len(uid) <= 128):
            raise ValueError
    except (ValueError, KeyError, TypeError, binascii.Error):
        raise invalid_token() from None
    try:
        async with httpx.AsyncClient(timeout=8) as client:
            response = await client.post(LOOKUP_URL, headers={'X-Goog-Api-Key': key},
                                         json={'idToken': token})
    except httpx.HTTPError:
        raise HTTPException(503, '登录服务暂不可用，请稍后重试') from None
    if response.status_code in (400, 401):
        raise invalid_token()
    if response.status_code != 200:
        raise HTTPException(503, '登录服务暂不可用，请稍后重试')
    try:
        user, = response.json()['users']
        if user['localId'] != uid or user.get('disabled'):
            raise ValueError
        subject, = [p['rawId'] for p in user['providerUserInfo'] if p['providerId'] == provider]
        if not isinstance(subject, str) or not 1 <= len(subject) <= 255:
            raise ValueError
    except (ValueError, KeyError, TypeError):
        raise invalid_token() from None
    email = user.get('email')
    email = email.strip().lower() if isinstance(email, str) else None
    if user.get('emailVerified') is not True or not email or not email_auth.EMAIL.fullmatch(email):
        email = None
    return Identity(project, provider, subject, email)


@router.post('/firebase/login')
async def login(data: FirebaseLogin, request: Request):
    backend.require(request, login_only=not data.link)
    current = backend.ACCOUNT.get()
    device = email_auth.device_digest(request)
    identity = await verify_token(data.id_token)
    lookup = (identity.project, identity.provider, identity.subject)
    with closing(backend.registry()) as c, c:
        c.execute('BEGIN IMMEDIATE')
        signed_in = c.execute('SELECT 1 FROM email_sessions WHERE token_hash=? AND account_id=?',
                              (device, current)).fetchone() is not None
        if data.link != signed_in:
            raise HTTPException(409, '请先登录 LifePages 账号再绑定' if data.link
                                else '请在当前账号中使用「绑定登录方式」')
        registered = c.execute('''SELECT account_id FROM firebase_identities
            WHERE project_id=? AND provider=? AND subject=?''', lookup).fetchone()
        if registered:
            account = registered['account_id']
            if data.link and account != current:
                raise HTTPException(409, '此登录方式已绑定另一个 LifePages 账号')
        else:
            email_owner = c.execute('SELECT account_id FROM email_accounts WHERE email=?',
                                    (identity.email,)).fetchone()
            if email_owner and email_owner['account_id'] != current:
                raise HTTPException(409, '此邮箱已有 LifePages 账号，请用验证码登录该账号后绑定')
            if not data.link and (
                email_owner
                or c.execute('SELECT 1 FROM email_accounts WHERE account_id=?', (current,)).fetchone()
                or c.execute('SELECT 1 FROM firebase_identities WHERE account_id=?', (current,)).fetchone()
            ):
                raise HTTPException(409, '请登录原有 LifePages 账号后绑定此登录方式')
            account = current
            c.execute('INSERT INTO firebase_identities VALUES(?,?,?,?)', (*lookup, account))
        if data.link:
            return {'ok': True}
        token = email_auth.issue_session(c, account)
    return {'email': identity.email, 'provider': identity.provider, 'token': token,
            'uses_current_account': account == current}
