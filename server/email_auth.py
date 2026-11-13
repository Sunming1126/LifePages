"""LifePages email verification and revocable account sessions."""
import hashlib
import hmac
import os
import re
import secrets
import smtplib
import ssl
import time
from contextlib import closing
from email.headerregistry import Address
from email.message import EmailMessage
from typing import Literal

from fastapi import APIRouter, HTTPException, Request
from pydantic import BaseModel, Field

from server import app as backend

router = APIRouter(prefix='/api/auth')
SCHEMA = """
CREATE TABLE IF NOT EXISTS email_accounts(
    email TEXT PRIMARY KEY, account_id TEXT NOT NULL UNIQUE REFERENCES accounts(id)
);
CREATE TABLE IF NOT EXISTS email_sessions(
    token_hash TEXT PRIMARY KEY, account_id TEXT NOT NULL REFERENCES accounts(id)
);
CREATE TABLE IF NOT EXISTS email_codes(
    email TEXT PRIMARY KEY, device_hash TEXT NOT NULL, digest TEXT NOT NULL,
    expires INTEGER NOT NULL, attempts INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS email_password_codes(
    email TEXT PRIMARY KEY, device_hash TEXT NOT NULL, digest TEXT NOT NULL,
    expires INTEGER NOT NULL, attempts INTEGER NOT NULL DEFAULT 0, purpose TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS email_send_attempts(
    email TEXT NOT NULL, account_id TEXT NOT NULL, sent INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS email_send_attempts_sent ON email_send_attempts(sent);
"""
EMAIL = re.compile(r"[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+")
COOLDOWN = 60
CODE_LIFETIME = 600


class EmailInput(BaseModel):
    email: str = Field(min_length=3, max_length=254)

    def normalized(self):
        value = self.email.strip().lower()
        if not EMAIL.fullmatch(value):
            raise HTTPException(400, '请输入有效的邮箱地址')
        return value


class VerifyInput(EmailInput):
    code: str = Field(pattern=r'^[0-9]{6}$')


class SendInput(EmailInput):
    purpose: Literal['login', 'register', 'reset'] = 'login'


def settings():
    values = {key: os.getenv(f'LIFEPAGES_SMTP_{key}', '')
              for key in ('HOST', 'PORT', 'SECURE', 'USER', 'PASS', 'FROM')}
    secret = os.getenv('LIFEPAGES_EMAIL_CODE_SECRET', '')
    if not all(values[key] for key in ('HOST', 'USER', 'PASS', 'FROM')) or len(secret) < 32:
        raise HTTPException(503, '邮箱登录暂未开通')
    return values, secret


def smtp_connection(config):
    port = int(config['PORT'] or '465')
    secure = (config['SECURE'].lower() == 'true') if config['SECURE'] else port == 465
    context = ssl.create_default_context()
    if secure:
        return smtplib.SMTP_SSL(config['HOST'], port, timeout=12, context=context)
    connection = smtplib.SMTP(config['HOST'], port, timeout=12)
    try:
        connection.starttls(context=context)
        return connection
    except Exception:
        connection.close()
        raise


def send_message(config, email, code):
    message = EmailMessage()
    message['From'] = Address('LifePages', addr_spec=config['FROM'])
    message['To'] = Address(addr_spec=email)
    message['Subject'] = 'LifePages 登录验证码'
    message.set_content(f'您的 LifePages 登录验证码是 {code}，10 分钟内有效。\n'
                        '如果您没有发起登录，可以忽略此邮件。')
    with smtp_connection(config) as mail:
        mail.login(config['USER'], config['PASS'])
        mail.send_message(message)


def code_digest(secret, email, device_hash, code, purpose='login'):
    message = f'{email}\0{device_hash}\0{code}'
    if purpose != 'login':
        message += f'\0{purpose}'
    return hmac.new(secret.encode(), message.encode(), hashlib.sha256).hexdigest()


def device_digest(request):
    return backend.token_hash(request.headers['authorization'][7:])


def issue_session(c, account):
    # The existing table also serves Firebase sign-ins so all authenticated
    # sessions use the same API, RTC and logout credential checks.
    token = secrets.token_urlsafe(32)
    c.execute('INSERT INTO email_sessions VALUES(?,?)', (backend.token_hash(token), account))
    return token


def session_result(email, token, account, current):
    return {'email': email, 'token': token, 'uses_current_account': account == current}


def verify_code(c, secret, email, device_hash, code, purpose='login'):
    table = 'email_codes' if purpose == 'login' else 'email_password_codes'
    row = c.execute(f'SELECT * FROM {table} WHERE email=?', (email,)).fetchone()
    if (row is None or row['expires'] <= int(time.time()) or row['device_hash'] != device_hash
            or row['attempts'] >= 5 or (purpose != 'login' and row['purpose'] != purpose)):
        raise HTTPException(400, '验证码已失效，请重新发送')
    expected = code_digest(secret, email, device_hash, code, purpose)
    if not hmac.compare_digest(row['digest'], expected):
        c.execute(f'UPDATE {table} SET attempts=attempts+1 WHERE email=?', (email,))
        c.commit()
        raise HTTPException(400, '验证码不正确')
    c.execute(f'DELETE FROM {table} WHERE email=?', (email,))


def email_account(c, email, current, *, create, credential=None):
    bound = c.execute('SELECT email FROM email_accounts WHERE account_id=?', (current,)).fetchone()
    if bound is not None and bound['email'] != email:
        raise HTTPException(409, '请先退出当前账号')
    registered = c.execute('SELECT account_id FROM email_accounts WHERE email=?', (email,)).fetchone()
    if registered:
        return registered['account_id']
    if create:
        social = c.execute('SELECT 1 FROM firebase_identities WHERE account_id=?', (current,)).fetchone()
        if social and not c.execute('SELECT 1 FROM email_sessions WHERE token_hash=? AND account_id=?',
                                    (credential, current)).fetchone():
            raise HTTPException(409, '请用原登录方式进入此账号')
        c.execute('INSERT INTO email_accounts VALUES(?,?)', (email, current))
        return current
    return None


@router.post('/email-code/send')
def send(data: SendInput, request: Request):
    backend.require(request, login_only=True)
    config, secret = settings()
    email, device_hash = data.normalized(), device_digest(request)
    now = int(time.time())
    code = f'{secrets.randbelow(1_000_000):06d}'
    purpose = data.purpose
    table = 'email_codes' if purpose == 'login' else 'email_password_codes'
    digest = code_digest(secret, email, device_hash, code, purpose)
    with closing(backend.registry()) as c, c:
        c.execute('BEGIN IMMEDIATE')
        c.execute('DELETE FROM email_send_attempts WHERE sent<=?', (now - 3600,))
        c.execute('DELETE FROM email_codes WHERE expires<=?', (now,))
        c.execute('DELETE FROM email_password_codes WHERE expires<=?', (now,))
        counts = c.execute('''SELECT COUNT(*), COUNT(CASE WHEN account_id=? THEN 1 END),
            COUNT(CASE WHEN email=? THEN 1 END), MAX(CASE WHEN email=? THEN sent END)
            FROM email_send_attempts''', (backend.ACCOUNT.get(), email, email)).fetchone()
        total, by_device, by_email, last = counts
        if (last is not None and now - last < COOLDOWN) or by_device >= 5 or by_email >= 5 or total >= 100:
            raise HTTPException(429, '发送过于频繁，请稍后再试')
        c.execute('INSERT INTO email_send_attempts VALUES(?,?,?)', (email, backend.ACCOUNT.get(), now))
        if purpose == 'login':
            c.execute('INSERT OR REPLACE INTO email_codes VALUES(?,?,?,?,0)',
                      (email, device_hash, digest, now + CODE_LIFETIME))
        else:
            c.execute('INSERT OR REPLACE INTO email_password_codes VALUES(?,?,?,?,0,?)',
                      (email, device_hash, digest, now + CODE_LIFETIME, purpose))
    try:
        send_message(config, email, code)
    except (OSError, smtplib.SMTPException, ValueError):
        with closing(backend.registry()) as c, c:
            c.execute(f'DELETE FROM {table} WHERE email=? AND digest=?', (email, digest))
        raise HTTPException(502, '验证码发送失败，请稍后再试') from None
    return {'retry_after': COOLDOWN, 'expires_in': CODE_LIFETIME}


@router.post('/email-code/login')
def login(data: VerifyInput, request: Request):
    backend.require(request, login_only=True)
    _, secret = settings()
    email, device_hash = data.normalized(), device_digest(request)
    guest = backend.ACCOUNT.get()
    with closing(backend.registry()) as c, c:
        c.execute('BEGIN IMMEDIATE')
        verify_code(c, secret, email, device_hash, data.code)
        account = email_account(c, email, guest, create=True, credential=device_hash)
        token = issue_session(c, account)
    return session_result(email, token, account, guest)


@router.post('/logout')
def logout(request: Request):
    header = request.headers.get('authorization', '')
    if not re.fullmatch(r'Bearer [A-Za-z0-9_-]{40,100}', header):
        raise HTTPException(401, '需要有效的设备凭证')
    with closing(backend.registry()) as c, c:
        c.execute('DELETE FROM email_sessions WHERE token_hash=?', (device_digest(request),))
    return {'ok': True}
