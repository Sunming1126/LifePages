"""Resolve LifePages credentials for the API and the RTC sidecar."""

import hashlib
import re


def token_hash(token):
    return hashlib.sha256(token.encode()).hexdigest()


def bearer_digest(header):
    match = re.fullmatch(r'Bearer ([A-Za-z0-9_-]{40,100})', header or '')
    return token_hash(match[1]) if match else None


def resolve_account(conn, digest, *, login_only=False):
    if digest is None:
        return None
    # A former guest credential can retry a verified login after a lost
    # response. It cannot open the signed-in account's data or playback.
    row = conn.execute('''
        SELECT account_id FROM email_sessions WHERE token_hash=?
        UNION ALL
        SELECT a.id FROM accounts a WHERE a.token_hash=? AND (
            ? OR (
                NOT EXISTS (SELECT 1 FROM email_accounts WHERE account_id=a.id)
                AND NOT EXISTS (SELECT 1 FROM firebase_identities WHERE account_id=a.id)
            )
        )
        LIMIT 1
    ''', (digest, digest, login_only)).fetchone()
    return row[0] if row else None
