import asyncio
import json
import sqlite3
import tempfile
import time
import unittest
from contextlib import ExitStack, closing
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from unittest.mock import AsyncMock, patch

from fastapi.testclient import TestClient

from deploy.prepare_rtc_env import prepare
from server import rtc_gateway, rtc_playback
from server.account_access import token_hash


class RtcEnvironmentTest(unittest.TestCase):
    def test_agent_sets_one_speaker_and_a_consistent_reading_style(self):
        settings = dict.fromkeys(rtc_gateway.REQUIRED, 'test-value')
        settings.update(OPENSPEECH_API_KEY='test-value', OPENSPEECH_VOICE_TYPE='fixed-speaker',
                        RTC_TTS_RESOURCE_ID='seed-tts-2.0')
        with patch.dict('os.environ', settings):
            config = rtc_gateway.agent_config('listener', 'reader')
        params = config['Config']['TTSConfig']['ProviderParams']
        voice = json.loads(params['VolcanoTTSParameters'])['req_params']
        self.assertEqual(params['Credential']['ResourceId'], 'seed-tts-2.0')
        self.assertEqual(voice['speaker'], 'fixed-speaker')
        self.assertEqual(voice['audio_params'], {'speech_rate': 0, 'loudness_rate': 0})
        self.assertTrue(voice['additions']['context_texts'])

    def test_copy_removes_inline_comments_and_pins_the_voice_resource_pair(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / 'saypal.env'
            destination = Path(directory) / 'rtc.env'
            source.write_text(
                'VOLC_RTC_APP_ID=012345678901234567890123 # RTC application\n'
                "VOLC_ACCESS_KEY='test-key' # credentials\n"
                'OPENSPEECH_VOICE_TYPE=old_voice\n'
                'UNRELATED=excluded\n'
            )
            prepare(source, destination, voice='new_voice', resource='seed-tts-2.0')
            self.assertEqual(destination.stat().st_mode & 0o777, 0o600)
            self.assertEqual(dict(line.split('=', 1) for line in destination.read_text().splitlines()), {
                'VOLC_RTC_APP_ID': '012345678901234567890123',
                'VOLC_ACCESS_KEY': 'test-key',
                'OPENSPEECH_VOICE_TYPE': 'new_voice',
                'RTC_TTS_RESOURCE_ID': 'seed-tts-2.0',
            })


class RtcPlaybackTest(unittest.TestCase):
    def setUp(self):
        resources = ExitStack()
        self.addCleanup(resources.close)
        directory = resources.enter_context(tempfile.TemporaryDirectory())
        data = Path(directory)
        resources.enter_context(patch.object(rtc_playback, 'DATA', data))
        settings = dict.fromkeys(rtc_gateway.REQUIRED, 'test-value')
        settings['OPENSPEECH_API_KEY'] = 'test-value'
        resources.enter_context(patch.dict('os.environ', settings))
        self.cloud = resources.enter_context(patch.object(rtc_gateway, 'call', new_callable=AsyncMock))
        self.owner, self.other = 'a' * 32, 'b' * 32
        self.reply, self.user_message, self.book = 'c' * 32, 'd' * 32, 'e' * 32
        self.other_reply, self.other_book = 'a' * 32, 'b' * 32
        self.headers = {'Authorization': 'Bearer ' + 'x' * 43}
        self.other_headers = {'Authorization': 'Bearer ' + 'y' * 43}
        self.text = '这是已保存的回复。' * 30
        with closing(sqlite3.connect(data / 'registry.sqlite3')) as registry, registry:
            registry.executescript('''
                CREATE TABLE accounts (id TEXT, token_hash TEXT);
                CREATE TABLE email_accounts (email TEXT, account_id TEXT);
                CREATE TABLE email_sessions (token_hash TEXT, account_id TEXT);
                CREATE TABLE firebase_identities (account_id TEXT);
            ''')
            for owner, token in ((self.owner, 'x' * 43), (self.other, 'y' * 43)):
                registry.execute(
                    'INSERT INTO accounts VALUES (?, ?)',
                    (owner, token_hash(token)),
                )
                account = data / 'accounts' / owner
                account.mkdir(parents=True)
                with closing(sqlite3.connect(account / 'lifepages.sqlite3')) as db, db:
                    db.execute('CREATE TABLE messages (id TEXT, person_id TEXT, role TEXT, text TEXT)')
                    db.execute('CREATE TABLE people (id TEXT)')
                    if owner == self.owner:
                        db.execute('INSERT INTO people VALUES (?)', (self.book,))
                        db.executemany('INSERT INTO messages VALUES (?, ?, ?, ?)', (
                            (self.reply, self.book, 'assistant', self.text),
                            (self.user_message, self.book, 'user', '我的录音转写'),
                        ))
                    else:
                        db.execute('INSERT INTO people VALUES (?)', (self.other_book,))
                        db.execute('INSERT INTO messages VALUES (?, ?, ?, ?)',
                                   (self.other_reply, self.other_book, 'assistant', '另一个账号的回复。'))
        self.client = resources.enter_context(TestClient(rtc_playback.app))

    def bootstrap(self, message_id, headers=None):
        return self.client.post('/api/rtc/sessions', json={'message_id': message_id}, headers=headers)

    def test_only_saved_assistant_replies_of_authenticated_owner_can_be_spoken(self):
        self.assertEqual(self.bootstrap(self.reply).status_code, 401)
        self.assertEqual(self.bootstrap(self.reply, self.other_headers).status_code, 404)
        self.assertEqual(self.bootstrap(self.user_message, self.headers).status_code, 404)
        response = self.bootstrap(self.reply, self.headers)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.headers['cache-control'], 'no-store')
        self.assertNotIn(self.text, response.text)
        path = '/api/rtc/sessions/' + response.json()['sessionId']
        self.assertEqual(
            self.client.post(path + '/speak', json={'segment': 0}, headers=self.other_headers).status_code,
            404,
        )
        self.cloud.assert_not_awaited()

    def test_only_the_opening_session_controls_a_room_and_revocation_marks_it_for_cleanup(self):
        first, second = 'm' * 43, 'n' * 43
        first_headers = {'Authorization': 'Bearer ' + first}
        second_headers = {'Authorization': 'Bearer ' + second}
        path = rtc_playback.DATA / 'registry.sqlite3'
        with closing(sqlite3.connect(path)) as conn, conn:
            conn.execute('INSERT INTO email_accounts VALUES (?,?)', ('rtc@example.test', self.owner))
            conn.executemany('INSERT INTO email_sessions VALUES (?,?)',
                             ((token_hash(token), self.owner) for token in (first, second)))
        self.assertEqual(self.bootstrap(self.reply, self.headers).status_code, 401)
        sid = self.bootstrap(self.reply, first_headers).json()['sessionId']
        endpoint = '/api/rtc/sessions/' + sid
        self.assertEqual(self.bootstrap(self.reply, second_headers).status_code, 429)
        self.assertEqual(self.client.post(endpoint + '/speak', json={'segment': 0},
                                          headers=second_headers).status_code, 404)
        self.client.delete(endpoint, headers=second_headers)
        self.assertEqual(self.client.post(endpoint + '/speak', json={'segment': 0},
                                          headers=first_headers).status_code, 200)
        with closing(sqlite3.connect(path)) as conn, conn:
            conn.execute('DELETE FROM email_sessions WHERE token_hash=?', (token_hash(first),))
        self.assertEqual(self.client.post(endpoint + '/speak', json={'segment': 1},
                                          headers=first_headers).status_code, 401)
        self.assertEqual(rtc_playback.revoked_rooms(tuple(rtc_playback.app.state.rooms.items())), {sid})

    def test_two_accounts_can_speak_in_parallel_in_distinct_rooms(self):
        rooms = [self.bootstrap(message, headers).json() for message, headers in
                 ((self.reply, self.headers), (self.other_reply, self.other_headers))]
        self.assertNotEqual(rooms[0]['roomId'], rooms[1]['roomId'])
        started = set()
        both_running = asyncio.Event()

        async def cloud(_client, operation, data):
            if operation == 'StartVoiceChat':
                started.add(data['RoomId'])
                if len(started) == 2:
                    both_running.set()
                await asyncio.wait_for(both_running.wait(), timeout=3)

        self.cloud.side_effect = cloud

        def speak(room, headers):
            return self.client.post('/api/rtc/sessions/' + room['sessionId'] + '/speak',
                                    headers=headers, json={'segment': 0})

        with ThreadPoolExecutor(max_workers=2) as pool:
            tasks = [pool.submit(speak, room, headers)
                     for room, headers in zip(rooms, (self.headers, self.other_headers))]
            self.assertEqual([task.result().status_code for task in tasks], [200, 200])
        self.assertEqual(started, {room['roomId'] for room in rooms})

    def test_voice_choice_is_allowlisted_and_fixed_for_replay_room(self):
        endpoint = '/api/rtc/sessions'
        body = {'message_id': self.reply, 'voice_id': 'yunzhou'}
        invalid = self.client.post(endpoint, json={**body, 'voice_id': 'unapproved'}, headers=self.headers)
        self.assertEqual(invalid.status_code, 422)
        room = self.client.post(endpoint, json=body, headers=self.headers).json()
        same = self.client.post(endpoint, json=body, headers=self.headers).json()
        self.assertEqual(same['sessionId'], room['sessionId'])
        changed = self.client.post(endpoint, json={**body, 'voice_id': 'vivi'}, headers=self.headers)
        self.assertEqual(changed.status_code, 429)
        path = '/api/rtc/sessions/' + room['sessionId']
        for index in (0, 1):
            self.assertEqual(self.client.post(path + '/speak', json={'segment': index}, headers=self.headers).status_code, 200)
        calls = [call.args for call in self.cloud.await_args_list]
        self.assertEqual([args[1] for args in calls], ['StartVoiceChat', 'UpdateVoiceChat', 'UpdateVoiceChat'])
        params = calls[0][2]['Config']['TTSConfig']['ProviderParams']
        self.assertEqual(json.loads(params['VolcanoTTSParameters'])['req_params']['speaker'],
                         rtc_gateway.VOICE_PRESETS['yunzhou'])

    def test_playback_is_ordered_and_retry_does_not_repeat_speech(self):
        room = self.bootstrap(self.reply, self.headers).json()
        self.assertGreater(room['segments'], 1)
        path = '/api/rtc/sessions/' + room['sessionId']
        for index in [1, 0, 0, *range(1, room['segments'])]:
            result = self.client.post(path + '/speak', json={'segment': index}, headers=self.headers)
            if not self.cloud.await_count:
                self.assertEqual(result.status_code, 409)
            else:
                self.assertEqual(result.status_code, 200)
        self.assertEqual(self.client.delete(path, headers=self.headers).status_code, 200)
        self.assertEqual(self.client.delete(path, headers=self.headers).status_code, 200)
        calls = [item.args for item in self.cloud.await_args_list]
        self.assertEqual([args[1] for args in calls], [
            'StartVoiceChat', *['UpdateVoiceChat'] * room['segments'], 'StopVoiceChat',
        ])
        segments = [args[2]['Message'] for args in calls[1:-1]]
        self.assertTrue(all(len(item) <= 200 for item in segments))
        self.assertEqual(''.join(segments), self.text)

    def test_streaming_room_prewarms_and_speaks_only_the_stored_segment(self):
        request_id = 'f' * 32
        body = {'book_id': self.book, 'request_id': request_id, 'voice_id': 'xiaohe'}
        self.assertEqual(self.client.post('/api/rtc/turns', json=body, headers=self.other_headers).status_code, 404)
        room = self.client.post('/api/rtc/turns', json=body, headers=self.headers).json()
        path = '/api/rtc/sessions/' + room['sessionId']
        self.assertEqual(self.client.post(path + '/start', headers=self.headers).status_code, 200)
        self.assertEqual(self.cloud.await_args.args[1], 'StartVoiceChat')
        config = self.cloud.await_args.args[2]['Config']['TTSConfig']['ProviderParams']
        self.assertEqual(json.loads(config['VolcanoTTSParameters'])['req_params']['speaker'],
                         rtc_gateway.VOICE_PRESETS['xiaohe'])
        self.assertEqual(self.client.post(path + '/speak', json={'segment': 0}, headers=self.headers).status_code, 409)
        with closing(sqlite3.connect(rtc_playback.DATA / 'accounts' / self.owner / 'lifepages.sqlite3')) as db, db:
            db.execute('CREATE TABLE chat_turns (request_id TEXT, person_id TEXT)')
            db.execute('CREATE TABLE rtc_turn_segments (request_id TEXT, segment INTEGER, text TEXT, created INTEGER)')
            db.execute('INSERT INTO chat_turns VALUES (?,?)', (request_id, self.book))
            db.execute('INSERT INTO rtc_turn_segments VALUES (?,?,?,?)', (request_id, 0, '那晚的星空真美，', int(time.time())))
        response = self.client.post(path + '/speak', json={'segment': 0, 'text': '任意文字'}, headers=self.headers)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(self.cloud.await_args.args[2]['Message'], '那晚的星空真美。')
        self.assertEqual(self.cloud.await_count, 2)

    def test_warm_room_reuses_one_agent_and_rejects_old_or_cross_book_turns(self):
        first, second, other_book = ('f' * 32, '1' * 32, '2' * 32)
        with closing(sqlite3.connect(rtc_playback.DATA / 'accounts' / self.owner / 'lifepages.sqlite3')) as db, db:
            db.execute('CREATE TABLE chat_turns (request_id TEXT, person_id TEXT)')
            db.execute('CREATE TABLE rtc_turn_segments (request_id TEXT, segment INTEGER, text TEXT, created INTEGER)')
            for rid, bid, text in ((first, self.book, '虚构第一条。'), (second, self.book, '虚构第二条。'),
                                   (other_book, self.other_book, '另一书稿。')):
                db.execute('INSERT INTO chat_turns VALUES (?,?)', (rid, bid))
                db.execute('INSERT INTO rtc_turn_segments VALUES (?,?,?,?)', (rid, 0, text, int(time.time())))
        room = self.client.post('/api/rtc/warm', json={'book_id': self.book}, headers=self.headers)
        self.assertEqual(room.status_code, 200)
        path = '/api/rtc/sessions/' + room.json()['sessionId']
        self.assertEqual(self.client.post(path + '/start', headers=self.headers).status_code, 200)
        self.assertEqual(self.cloud.await_count, 1)

        def speak(rid, headers=None):
            return self.client.post(path + '/speak', json={'segment': 0, 'request_id': rid},
                                    headers=headers or self.headers).status_code

        def finish(rid):
            return self.client.post(path + '/finish', json={'request_id': rid}, headers=self.headers).status_code

        legacy = self.bootstrap(self.reply, self.headers)
        self.assertEqual(legacy.status_code, 200)
        self.assertEqual(speak(first), 429)
        self.client.delete('/api/rtc/sessions/' + legacy.json()['sessionId'], headers=self.headers)
        self.assertEqual(speak(first, self.other_headers), 404)
        self.assertEqual(speak(other_book), 409)
        self.assertEqual(speak(first), 200)
        self.assertEqual(speak(first), 200)
        self.assertEqual(speak(second), 409)
        self.assertEqual(finish(first), 200)
        self.assertEqual(speak(second), 200)
        self.assertEqual(finish(first), 200)
        self.assertEqual(speak(first), 409)
        self.assertEqual(finish(second), 200)
        self.client.delete(path, headers=self.headers)
        calls = [call.args for call in self.cloud.await_args_list]
        self.assertEqual([args[1] for args in calls], [
            'StartVoiceChat', 'UpdateVoiceChat', 'UpdateVoiceChat', 'StopVoiceChat',
        ])
        self.assertEqual([args[2]['Message'] for args in calls[1:3]], ['虚构第一条。', '虚构第二条。'])
