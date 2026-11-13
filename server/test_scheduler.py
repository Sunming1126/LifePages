import json
import tempfile
import unittest
import uuid
from contextlib import closing
from pathlib import Path
from unittest.mock import patch

from server import app as backend
from server import scheduler


class DailyDraftTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.old_data, self.old_registry = backend.DATA, backend.REGISTRY
        backend.DATA = Path(self.tmp.name)
        (backend.DATA / 'accounts').mkdir()
        backend.REGISTRY = backend.DATA / 'registry.sqlite3'
        backend.init_registry()
        self.create_account()

    def tearDown(self):
        backend.DATA, backend.REGISTRY = self.old_data, self.old_registry
        self.tmp.cleanup()

    def create_account(self):
        token = backend.bootstrap()['token']
        backend.authorized('Bearer ' + token)
        account = backend.ACCOUNT.get()
        person = uuid.uuid4().hex
        with closing(backend.db()) as c:
            c.execute('CREATE TABLE ai_privacy (id INTEGER PRIMARY KEY, enabled INTEGER NOT NULL)')
            c.execute('INSERT INTO ai_privacy VALUES(1,1)')
            c.execute('INSERT INTO people(id,name,background) VALUES(?,?,?)', (person, '奶奶', '海边'))
            c.commit()
        return account, person

    def add(self, person, text, audio=False):
        mid = uuid.uuid4().hex
        with closing(backend.db()) as c:
            c.execute('INSERT INTO messages(id,person_id,role,text,audio) VALUES(?,?,?,?,?)',
                      (mid, person, 'user', text, mid + '.wav' if audio else None))
            c.commit()
        return mid

    def seed(self, person):
        return [self.add(person, '小时候，我住在海边的小村子里，每天和家人一起在海岸散步。' * 2, audio=i == 0)
                for i in range(3)]

    @staticmethod
    async def good_llm(system, context):
        return json.dumps({'should_create': True, 'title': '海边的童年', 'content': '我小时候住在海边。'}, ensure_ascii=False)

    async def test_threshold_and_idempotency_with_audio(self):
        account, person = self.create_account()
        self.add(person, '一小段')
        with patch.object(backend, 'llm', self.good_llm):
            self.assertEqual(await scheduler.process_person(person), 'insufficient')
            ids = self.seed(person)
            self.assertEqual(await scheduler.process_person(person), 'created')
            self.assertEqual(await scheduler.process_person(person), 'insufficient')
        with closing(backend.db()) as c:
            self.assertEqual(c.execute('SELECT COUNT(*) FROM chapters').fetchone()[0], 1)
            self.assertEqual(c.execute('SELECT COUNT(*) FROM chapter_sources').fetchone()[0], 4)
            self.assertEqual(c.execute('SELECT message_id FROM chapter_audio').fetchone()[0], ids[0])
            c.execute('UPDATE chapters SET content=?', ('家人核对后的文字',)); c.commit()
        with patch.object(backend, 'llm', self.good_llm):
            await scheduler.process_person(person)
        with closing(backend.db()) as c:
            self.assertEqual(c.execute('SELECT content FROM chapters').fetchone()[0], '家人核对后的文字')

    async def test_failure_does_not_consume_and_retry(self):
        _, person = self.create_account()
        self.seed(person)
        async def fails(system, context):
            raise RuntimeError('provider failed')
        with patch.object(backend, 'llm', fails):
            with self.assertRaises(RuntimeError):
                await scheduler.process_person(person)
        with closing(backend.db()) as c:
            self.assertEqual(c.execute('SELECT COUNT(*) FROM chapter_sources').fetchone()[0], 0)
        with patch.object(backend, 'llm', self.good_llm):
            self.assertEqual(await scheduler.process_person(person), 'created')

    async def test_manual_commit_during_generation_does_not_duplicate(self):
        _, person = self.create_account()
        ids = self.seed(person)
        async def concurrent_manual(system, context):
            with closing(backend.db()) as c:
                c.execute('INSERT INTO chapters(id,person_id,title,content,position) VALUES(?,?,?,?,?)',
                          ('manual', person, '手动章', '内容', 0))
                c.executemany('INSERT INTO chapter_sources(chapter_id,message_id) VALUES(?,?)',
                              [('manual', mid) for mid in ids]); c.commit()
            return await self.good_llm(system, context)
        with patch.object(backend, 'llm', concurrent_manual):
            self.assertEqual(await scheduler.process_person(person), 'conflict')
        with closing(backend.db()) as c:
            self.assertEqual(c.execute('SELECT COUNT(*) FROM chapters').fetchone()[0], 1)

    async def test_all_accounts_independent_and_no_story_does_not_consume(self):
        first, person_a = self.create_account(); self.seed(person_a)
        second, person_b = self.create_account(); self.seed(person_b)
        async def no_story(system, context):
            return '{"should_create": false, "title": "", "content": ""}'
        with patch.object(backend, 'llm', no_story):
            counts = await scheduler.run_once()
        self.assertEqual(counts['no_story'], 2)
        with patch.object(backend, 'llm', self.good_llm):
            unchanged = await scheduler.run_once()
        self.assertEqual(unchanged['created'], 0)
        for account, person in [(first, person_a), (second, person_b)]:
            backend.ACCOUNT.set(account)
            self.add(person, '又想起一段新的经历。')
        with patch.object(backend, 'llm', self.good_llm):
            counts = await scheduler.run_once()
        self.assertEqual(counts['created'], 2)
        for account in [first, second]:
            backend.ACCOUNT.set(account)
            with closing(backend.db()) as c:
                self.assertEqual(c.execute('SELECT COUNT(*) FROM chapters').fetchone()[0], 1)

if __name__ == '__main__':
    unittest.main()
