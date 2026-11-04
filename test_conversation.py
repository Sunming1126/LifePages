import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from fastapi.testclient import TestClient
import app


class ConversationTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.old_data, self.old_audio = app.DATA, app.AUDIO
        app.DATA = Path(self.tmp.name)
        app.AUDIO = app.DATA / 'audio'
        app.AUDIO.mkdir()
        with app.db() as c:
            c.executescript('''CREATE TABLE project(id INTEGER PRIMARY KEY, name TEXT NOT NULL, birth_year TEXT NOT NULL DEFAULT '', hometown TEXT NOT NULL DEFAULT '', background TEXT NOT NULL DEFAULT '');
            CREATE TABLE stories(id INTEGER PRIMARY KEY, project_id INTEGER NOT NULL, title TEXT NOT NULL, content TEXT NOT NULL DEFAULT '', question TEXT NOT NULL DEFAULT '');
            CREATE TABLE recordings(id INTEGER PRIMARY KEY, story_id INTEGER NOT NULL, filename TEXT NOT NULL, transcript TEXT NOT NULL DEFAULT '', question TEXT NOT NULL DEFAULT '', created TEXT DEFAULT CURRENT_TIMESTAMP);
            CREATE TABLE messages(id INTEGER PRIMARY KEY, story_id INTEGER NOT NULL, role TEXT NOT NULL, content TEXT NOT NULL, recording_id INTEGER, created TEXT DEFAULT CURRENT_TIMESTAMP);''')
        self.client = TestClient(app.app)

    def tearDown(self):
        app.DATA, app.AUDIO = self.old_data, self.old_audio
        self.tmp.cleanup()

    def test_profiles_messages_and_recordings_stay_separate(self):
        client = self.client
        first = client.post('/api/projects', json={'name': 'Grandma', 'hometown': 'Suzhou'}).json()['id']
        second = client.post('/api/projects', json={'name': 'Grandpa'}).json()['id']
        sid = client.post('/api/stories', json={'project_id': first, 'title': 'Childhood'}).json()['id']
        rid = client.post(f'/api/stories/{sid}/recordings', files={'audio': ('x.webm', b'audio', 'audio/webm')}).json()['id']
        result = client.post(f'/api/stories/{sid}/messages', json={'content': 'I lived by the river.', 'recording_id': rid})
        self.assertEqual(result.status_code, 200)
        self.assertEqual(client.get(f'/api/stories/{sid}').json()['messages'][0]['content'], 'I lived by the river.')
        self.assertEqual(client.get(f'/api/recordings/{rid}/audio').content, b'audio')
        self.assertEqual(client.get(f'/api/projects/{second}/stories').json(), [])
        self.assertEqual(client.post(f'/api/stories/{sid}/conversation/start').status_code, 400)
        self.assertEqual(client.get(f'/api/stories/{sid}/qr').status_code, 200)

    def test_ai_failure_preserves_answer(self):
        client = self.client
        pid = client.post('/api/projects', json={'name': 'Test'}).json()['id']
        sid = client.post('/api/stories', json={'project_id': pid, 'title': 'Story'}).json()['id']
        client.post(f'/api/stories/{sid}/messages', json={'content': 'A memory'})
        with patch.object(app, 'api_config', side_effect=app.HTTPException(400, 'missing')):
            self.assertEqual(client.post(f'/api/stories/{sid}/conversation/next').status_code, 400)
        self.assertEqual(client.get(f'/api/stories/{sid}').json()['messages'][0]['content'], 'A memory')


if __name__ == '__main__':
    unittest.main()
