import re
import unittest
from unittest.mock import MagicMock, patch

from fastapi import HTTPException

from server.test_app import backend, httpx
from server import email_auth, rtc_playback


class EmailAuthTests(unittest.IsolatedAsyncioTestCase):
    async def test_email_login_binds_guest_and_restores_books_on_another_device(self):
        env = {'LIFEPAGES_SMTP_HOST': 'mail.example.test',
               'LIFEPAGES_SMTP_USER': 'sender@example.test',
               'LIFEPAGES_SMTP_PASS': 'synthetic-test-only',
               'LIFEPAGES_SMTP_FROM': 'sender@example.test',
               'LIFEPAGES_EMAIL_CODE_SECRET': 'test-only-key-' * 4}
        transport = httpx.ASGITransport(app=backend.app)
        async with httpx.AsyncClient(transport=transport, base_url='http://test') as client:
            async def guest():
                token = (await client.post('/api/bootstrap')).json()['token']
                return {'Authorization': f'Bearer {token}'}

            first, second = await guest(), await guest()
            own = (await client.get('/api/books', headers=first)).json()['active_id']
            other = (await client.get('/api/books', headers=second)).json()['active_id']
            email = f'{own}@example.test'
            connection = MagicMock()
            mail = connection.__enter__.return_value
            with patch.dict('os.environ', env), patch.object(email_auth, 'smtp_connection', return_value=connection), \
                    patch.object(email_auth.time, 'time', return_value=100_000) as clock:
                async def send(device):
                    result = await client.post('/api/auth/email-code/send', headers=device, json={'email': email})
                    self.assertEqual(result.status_code, 200, result.text)
                    msg = mail.send_message.call_args.args[0]
                    self.assertEqual(msg['From'].addresses[0].display_name, 'LifePages')
                    self.assertEqual(msg['To'].addresses[0].addr_spec, email)
                    return re.search(r'\d{6}', msg.get_content())[0]

                async def login(device, code):
                    return await client.post('/api/auth/email-code/login', headers=device,
                                             json={'email': email, 'code': code})

                code = await send(first)
                duplicate = await client.post('/api/auth/email-code/send', headers=first, json={'email': email})
                self.assertEqual(duplicate.status_code, 429)
                self.assertEqual((await login(second, code)).status_code, 400)
                self.assertEqual((await login(first, str((int(code) + 1) % 1_000_000).zfill(6))).status_code, 400)
                first_session = (await login(first, code)).json()
                self.assertTrue(first_session['uses_current_account'])
                self.assertEqual((await login(first, code)).status_code, 400)
                self.assertEqual((await client.get('/api/books', headers=first)).status_code, 401)

                clock.return_value += 61
                recovered = (await login(first, await send(first))).json()
                self.assertTrue(recovered['uses_current_account'])
                same_account = {'Authorization': 'Bearer ' + recovered['token']}

                clock.return_value += 61
                second_session = (await login(second, await send(second))).json()
                self.assertFalse(second_session['uses_current_account'])
                authenticated = {'Authorization': 'Bearer ' + second_session['token']}
                self.assertEqual((await client.get('/api/books', headers=authenticated)).json()['active_id'], own)
                self.assertEqual((await client.get('/api/books', headers=second)).json()['active_id'], other)
                backend.authorized(authenticated['Authorization'])
                with patch.object(rtc_playback, 'DATA', backend.DATA):
                    self.assertEqual(rtc_playback.account_session(authenticated['Authorization'])[0],
                                     backend.ACCOUNT.get())
                    with self.assertRaises(HTTPException) as rejected:
                        rtc_playback.account_session(first['Authorization'])
                    self.assertEqual(rejected.exception.status_code, 401)
                self.assertEqual((await client.post('/api/auth/logout', headers=authenticated)).status_code, 200)
                self.assertEqual((await client.get('/api/books', headers=authenticated)).status_code, 401)
                self.assertEqual((await client.get('/api/books', headers=same_account)).json()['active_id'], own)

    async def test_password_setup_and_reset_keep_the_verified_email_account(self):
        env = {'LIFEPAGES_SMTP_HOST': 'mail.example.test',
               'LIFEPAGES_SMTP_USER': 'sender@example.test',
               'LIFEPAGES_SMTP_PASS': 'synthetic-test-only',
               'LIFEPAGES_SMTP_FROM': 'sender@example.test',
               'LIFEPAGES_EMAIL_CODE_SECRET': 'test-only-key-' * 4}
        transport = httpx.ASGITransport(app=backend.app)
        async with httpx.AsyncClient(transport=transport, base_url='http://test') as client:
            async def guest():
                token = (await client.post('/api/bootstrap')).json()['token']
                return {'Authorization': 'Bearer ' + token}

            first, second = await guest(), await guest()
            book = (await client.get('/api/books', headers=first)).json()['active_id']
            email = f'{book}@example.test'
            connection = MagicMock()
            mail = connection.__enter__.return_value
            with patch.dict('os.environ', env), patch.object(email_auth, 'smtp_connection', return_value=connection), \
                    patch.object(email_auth.time, 'time', return_value=100_000) as clock:
                async def post(path, device, **fields):
                    return await client.post(f'/api/auth/{path}', headers=device,
                                             json={'email': email, **fields})

                async def code(device, purpose):
                    result = await post('email-code/send', device, purpose=purpose)
                    self.assertEqual(result.status_code, 200, result.text)
                    return re.search(r'\d{6}', mail.send_message.call_args.args[0].get_content())[0]

                def authorized(result):
                    self.assertEqual(result.status_code, 200, result.text)
                    return {'Authorization': 'Bearer ' + result.json()['token']}

                otp = await code(first, 'login')
                original = await post('email-code/login', first, code=otp)
                original_session = authorized(original)
                old_password = 'FirstPass123!'
                self.assertEqual((await post('email-password/login', second, password=old_password)).status_code, 401)

                clock.return_value += 61
                otp = await code(second, 'register')
                self.assertEqual((await post('email-password/register', first, code=otp, password=old_password)).status_code, 400)
                self.assertEqual((await post('email-password/reset', second, code=otp, password=old_password)).status_code, 400)
                created = await post('email-password/register', second, code=otp, password=old_password)
                created_session = authorized(created)
                self.assertFalse(created.json()['uses_current_account'])
                self.assertEqual((await client.get('/api/books', headers=created_session)).json()['active_id'], book)
                self.assertEqual((await post('email-password/register', second, code=otp, password=old_password)).status_code, 400)
                logged_in = authorized(await post('email-password/login', second, password=old_password))
                self.assertEqual((await client.get('/api/books', headers=logged_in)).json()['active_id'], book)

                clock.return_value += 61
                new_password = 'SecondPass456!'
                otp = await code(second, 'reset')
                reset = authorized(await post('email-password/reset', second, code=otp, password=new_password))
                for session in [first, original_session, created_session, logged_in]:
                    self.assertEqual((await client.get('/api/books', headers=session)).status_code, 401)
                self.assertEqual((await post('email-password/login', second, password=old_password)).status_code, 401)
                authorized(await post('email-password/login', second, password=new_password))
                self.assertEqual((await client.get('/api/books', headers=reset)).json()['active_id'], book)
