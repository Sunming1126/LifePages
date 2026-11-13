"""Password login for the same LifePages accounts used by email verification."""
import hashlib
import hmac
import secrets
import threading
import time
from contextlib import closing

from fastapi import APIRouter, HTTPException, Request
from pydantic import SecretStr

from server import app as backend, email_auth

router = APIRouter(prefix='/api/auth/email-password')
SCHEMA = """
CREATE TABLE IF NOT EXISTS email_passwords(
    email TEXT PRIMARY KEY REFERENCES email_accounts(email),
    salt BLOB NOT NULL, digest BLOB NOT NULL
);
CREATE TABLE IF NOT EXISTS email_password_attempts(
    email TEXT NOT NULL, device_hash TEXT NOT NULL, attempted INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS email_password_attempts_time ON email_password_attempts(attempted);
"""
_HASH_SLOTS = threading.BoundedSemaphore(4)
_DUMMY_SALT = b'\0' * 16


class PasswordLogin(email_auth.EmailInput):
    password: SecretStr


class SetPassword(email_auth.VerifyInput):
    password: SecretStr


def hash_password(password, salt):
    with _HASH_SLOTS:
        return hashlib.scrypt(password.encode(), salt=salt, n=2**15, r=8, p=3,
                              maxmem=64 * 1024 * 1024, dklen=32)


def invalid_login():
    return HTTPException(401, '邮箱或密码不正确')


@router.post('/login')
def login(data: PasswordLogin, request: Request):
    backend.require(request, login_only=True)
    email = data.normalized()
    password = data.password.get_secret_value()
    if not 1 <= len(password) <= 128:
        raise invalid_login()
    device = email_auth.device_digest(request)
    current = backend.ACCOUNT.get()
    now = int(time.time())
    with closing(backend.registry()) as c, c:
        c.execute('BEGIN IMMEDIATE')
        c.execute('DELETE FROM email_password_attempts WHERE attempted<=?', (now - 600,))
        total, by_email, by_device = c.execute('''SELECT COUNT(*),
            COUNT(CASE WHEN email=? THEN 1 END),COUNT(CASE WHEN device_hash=? THEN 1 END)
            FROM email_password_attempts''', (email, device)).fetchone()
        if total >= 300 or by_email >= 10 or by_device >= 20:
            raise HTTPException(429, '尝试次数过多，请稍后再试')
        c.execute('INSERT INTO email_password_attempts VALUES(?,?,?)', (email, device, now))
        saved = c.execute('SELECT salt,digest FROM email_passwords WHERE email=?', (email,)).fetchone()
    digest = hash_password(password, saved['salt'] if saved else _DUMMY_SALT)
    if not hmac.compare_digest(digest, saved['digest'] if saved else b'\0' * 32) or not saved:
        raise invalid_login()
    with closing(backend.registry()) as c, c:
        c.execute('BEGIN IMMEDIATE')
        latest = c.execute('SELECT salt,digest FROM email_passwords WHERE email=?', (email,)).fetchone()
        if latest is None or latest['salt'] != saved['salt'] or latest['digest'] != saved['digest']:
            raise invalid_login()
        account = email_auth.email_account(c, email, current, create=False)
        if account is None:
            raise invalid_login()
        token = email_auth.issue_session(c, account)
        c.execute('DELETE FROM email_password_attempts WHERE email=? AND device_hash=?', (email, device))
    return email_auth.session_result(email, token, account, current)


def set_password(data: SetPassword, request: Request, *, purpose):
    backend.require(request, login_only=True)
    _, secret = email_auth.settings()
    email = data.normalized()
    current = backend.ACCOUNT.get()
    password = data.password.get_secret_value()
    if not 8 <= len(password) <= 128 or not password.strip():
        raise HTTPException(400, '请输入 8 到 128 个字符的密码')
    with closing(backend.registry()) as c, c:
        c.execute('BEGIN IMMEDIATE')
        credential = email_auth.device_digest(request)
        email_auth.verify_code(c, secret, email, credential, data.code, purpose)
        account = email_auth.email_account(c, email, current, create=purpose == 'register',
                                          credential=credential)
        if account is None:
            raise HTTPException(400, '请先用此邮箱注册或通过验证码登录')
        existing = c.execute('SELECT 1 FROM email_passwords WHERE email=?', (email,)).fetchone()
        if purpose == 'register' and existing:
            raise HTTPException(409, '此邮箱已设置密码，请登录或重设密码')
        salt = secrets.token_bytes(16)
        digest = hash_password(password, salt)
        c.execute('''INSERT INTO email_passwords VALUES(?,?,?)
            ON CONFLICT(email) DO UPDATE SET salt=excluded.salt,digest=excluded.digest''',
                  (email, salt, digest))
        c.execute('DELETE FROM email_password_attempts WHERE email=?', (email,))
        if purpose == 'reset':
            c.execute('DELETE FROM email_sessions WHERE account_id=?', (account,))
            c.execute('DELETE FROM email_codes WHERE email=?', (email,))
        token = email_auth.issue_session(c, account)
    return email_auth.session_result(email, token, account, current)


@router.post('/register')
def register(data: SetPassword, request: Request):
    return set_password(data, request, purpose='register')


@router.post('/reset')
def reset(data: SetPassword, request: Request):
    return set_password(data, request, purpose='reset')
