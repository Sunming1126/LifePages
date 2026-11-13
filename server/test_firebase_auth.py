import base64
import json
import time
import unittest
from contextlib import closing
from unittest.mock import AsyncMock, patch

from server.test_app import backend, httpx
from server import email_auth, firebase_auth


def token_for(project, provider='apple.com'):
    payload = base64.urlsafe_b64encode(json.dumps({
        'iss': f'https://securetoken.google.com/{project}', 'aud': project,
        'sub': 'test-firebase-uid', 'firebase': {'sign_in_provider': provider},
    }).encode()).decode().rstrip('=')
    return f'header.{payload}.synthetic-signature'


class FirebaseAuthTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.client = httpx.AsyncClient(transport=httpx.ASGITransport(app=backend.app), base_url='http://test')

    async def asyncTearDown(self):
        await self.client.aclose()

    async def guest(self):
        result = await self.client.post('/api/bootstrap')
        return {'Authorization': 'Bearer ' + result.json()['token']}

    async def book(self, headers):
        result = await self.client.get('/api/books', headers=headers)
        self.assertEqual(result.status_code, 200, result.text)
        return result.json()['active_id']

    async def login(self, headers, *, link=False):
        return await self.client.post('/api/auth/firebase/login', headers=headers,
                                      json={'id_token': token_for('test-project'), 'link': link})

    async def test_verifies_project_token_and_returns_verified_provider_identity(self):
        token = token_for('test-project')
        verified = {'localId': 'test-firebase-uid', 'email': 'Test@Example.test',
                    'emailVerified': True,
                    'providerUserInfo': [{'providerId': 'apple.com', 'rawId': 'apple-subject'}]}
        seen = []

        def lookup(request):
            self.assertEqual(str(request.url), firebase_auth.LOOKUP_URL)
            self.assertEqual(request.headers['x-goog-api-key'], 'synthetic')
            self.assertEqual(json.loads(request.content), {'idToken': token})
            seen.append(request)
            return httpx.Response(200, json={'users': [verified]})

        transport = httpx.MockTransport(lookup)
        client_factory = httpx.AsyncClient
        with patch.dict('os.environ', {'LIFEPAGES_FIREBASE_PROJECT_ID': 'test-project',
                                       'LIFEPAGES_FIREBASE_API_KEY': 'synthetic'}), \
                patch.object(firebase_auth.httpx, 'AsyncClient', side_effect=lambda **kw: client_factory(
                    transport=transport, **kw)):
            for bad in (token_for('other-project'), token_for('test-project', 'password')):
                with self.assertRaises(firebase_auth.HTTPException) as error:
                    await firebase_auth.verify_token(bad)
                self.assertEqual(error.exception.status_code, 401)
            self.assertEqual(seen, [])
            identity = await firebase_auth.verify_token(token)
            self.assertEqual(identity, firebase_auth.Identity(
                'test-project', 'apple.com', 'apple-subject', 'test@example.test'))
            verified['disabled'] = True
            with self.assertRaises(firebase_auth.HTTPException) as error:
                await firebase_auth.verify_token(token)
            self.assertEqual(error.exception.status_code, 401)

    async def test_social_login_binds_guest_and_restores_books_on_another_device(self):
        first, second = await self.guest(), await self.guest()
        own, other = await self.book(first), await self.book(second)
        identity = firebase_auth.Identity('test-project', 'apple.com', own, None)
        with patch.object(firebase_auth, 'verify_token', AsyncMock(return_value=identity)):
            first_result = await self.login(first)
            self.assertEqual(first_result.status_code, 200, first_result.text)
            self.assertTrue(first_result.json()['uses_current_account'])
            self.assertIsNone(first_result.json()['email'])
            self.assertEqual((await self.client.get('/api/books', headers=first)).status_code, 401)
            self.assertEqual((await self.login(first)).status_code, 200)
            second_result = (await self.login(second)).json()
            self.assertFalse(second_result['uses_current_account'])
            session = {'Authorization': 'Bearer ' + second_result['token']}
            self.assertEqual(await self.book(session), own)
            self.assertEqual(await self.book(second), other)
            self.assertEqual((await self.client.post('/api/auth/logout', headers=session)).status_code, 200)
            self.assertEqual((await self.client.get('/api/books', headers=session)).status_code, 401)

    async def test_verified_email_collision_requires_explicit_account_link(self):
        old_guest, other_guest = await self.guest(), await self.guest()
        book = await self.book(old_guest)
        email = f'{book}@example.test'
        backend.authorized(old_guest['Authorization'])
        account = backend.ACCOUNT.get()
        with closing(backend.registry()) as c, c:
            c.execute('INSERT INTO email_accounts VALUES(?,?)', (email, account))
            old_session = {'Authorization': 'Bearer ' + email_auth.issue_session(c, account)}
        identity = firebase_auth.Identity('test-project', 'google.com', book, email)
        with patch.object(firebase_auth, 'verify_token', AsyncMock(return_value=identity)):
            self.assertEqual((await self.login(other_guest)).status_code, 409)
            self.assertEqual((await self.login(old_guest, link=True)).status_code, 401)
            self.assertEqual((await self.login(old_session, link=True)).json(), {'ok': True})
            self.assertEqual((await self.login(old_session, link=True)).json(), {'ok': True})
            signed_in = await self.login(other_guest)
            session = {'Authorization': 'Bearer ' + signed_in.json()['token']}
            self.assertEqual(await self.book(session), book)

    async def test_former_social_guest_cannot_attach_a_new_email(self):
        guest = await self.guest()
        book = await self.book(guest)
        identity = firebase_auth.Identity('test-project', 'apple.com', book, None)
        with patch.object(firebase_auth, 'verify_token', AsyncMock(return_value=identity)):
            self.assertEqual((await self.login(guest)).status_code, 200)

        email, code, secret = f'{book}@example.test', '123456', 'test-code-secret'
        credential = backend.token_hash(guest['Authorization'][7:])
        now = int(time.time())
        with closing(backend.registry()) as c, c:
            c.execute('INSERT INTO email_codes VALUES(?,?,?,?,0)',
                      (email, credential, email_auth.code_digest(secret, email, credential, code), now + 600))
            c.execute('INSERT INTO email_password_codes VALUES(?,?,?,?,0,?)',
                      (email, credential, email_auth.code_digest(secret, email, credential, code, 'register'),
                       now + 600, 'register'))
        with patch.object(email_auth, 'settings', return_value=({}, secret)):
            login = await self.client.post('/api/auth/email-code/login', headers=guest,
                                           json={'email': email, 'code': code})
            register = await self.client.post('/api/auth/email-password/register', headers=guest,
                                              json={'email': email, 'code': code, 'password': 'Test-only-password'})
        self.assertEqual([login.status_code, register.status_code], [409, 409])
        with closing(backend.registry()) as c:
            self.assertIsNone(c.execute('SELECT 1 FROM email_accounts WHERE email=?', (email,)).fetchone())
