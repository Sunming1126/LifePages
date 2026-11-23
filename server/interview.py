"""Interview state and evidence-backed transitions for a book's single conversation."""

import json
import re
import uuid

from fastapi import HTTPException

from server import chat_sessions, interview_memory
from server.interview_questions import BANKS, CURRENT_VERSION, DEPTH, SUPPLEMENT, rubric

INTRO = ('咱们先认识一下。您愿意我怎么称呼您？也可以说说您今年多大、家住哪个城市或区县。'
         '用昵称、说个大概，或者直接开始聊故事都可以。')
CLOSING = '预设的问题聊完了。您还可以在这里补讲，也可以把已经讲好的故事整理成书。'
MINIMUM_CHARACTERS = 301
REFUSALS = {'跳过', '跳过这题', '先不聊这个', '不想回答', '这个不想说', '这题不答了', '这段不要写进书里'}
NEXT = re.compile(r'(?:我想|我们|咱们|请|可以|直接)?(?:换到|进入|到|聊|讲|问|换)?下(?:一|个|一个)(?:个)?(?:题|问题|话题|章|章节)(?:吧|了|吗)?')
LEARNING_OPEN = '小时候，在上学或跟人学东西的时候，哪一件事您还记得？'
CLAUSE_END = re.compile(r'[。！？!?；;\n]+')
SCHEMA = (
    '''CREATE TABLE IF NOT EXISTS book_interviews(
        book_id TEXT PRIMARY KEY REFERENCES books(id) ON DELETE CASCADE,
        session_id TEXT UNIQUE NOT NULL REFERENCES chat_sessions(id),
        version INTEGER NOT NULL, question INTEGER NOT NULL DEFAULT 0,
        attempts INTEGER NOT NULL DEFAULT 0, revision INTEGER NOT NULL DEFAULT 0,
        intro_end INTEGER,
        first_message TEXT NOT NULL REFERENCES messages(id))''',
    '''CREATE TABLE IF NOT EXISTS interview_answers(
        book_id TEXT REFERENCES book_interviews(book_id) ON DELETE CASCADE,
        question INTEGER, skipped INTEGER NOT NULL DEFAULT 0,
        criteria TEXT NOT NULL, details TEXT NOT NULL, PRIMARY KEY(book_id, question))''',
    '''CREATE TABLE IF NOT EXISTS interview_drafts(
        book_id TEXT REFERENCES book_interviews(book_id) ON DELETE CASCADE,
        id TEXT PRIMARY KEY, revision INTEGER NOT NULL, chapters TEXT NOT NULL,
        saved INTEGER NOT NULL DEFAULT 0)''',
    '''CREATE UNIQUE INDEX IF NOT EXISTS interview_one_pending_draft
        ON interview_drafts(book_id) WHERE saved=0''',
    '''CREATE TABLE IF NOT EXISTS interview_chapters(
        topic_id TEXT PRIMARY KEY REFERENCES book_topics(id) ON DELETE CASCADE,
        questions TEXT NOT NULL)''',
    '''CREATE TABLE IF NOT EXISTS interview_chapter_passages(
        topic_id TEXT NOT NULL REFERENCES interview_chapters(topic_id) ON DELETE CASCADE,
        message_id TEXT NOT NULL REFERENCES messages(id), quote TEXT NOT NULL,
        PRIMARY KEY(topic_id,message_id,quote))''',
)


def ensure_schema(c):
    for statement in SCHEMA:
        c.execute(statement)


def find(c, bid):
    if not c.execute("SELECT 1 FROM sqlite_master WHERE name='book_interviews'").fetchone():
        return None
    return c.execute('SELECT * FROM book_interviews WHERE book_id=?', (bid,)).fetchone()


def start(c, bid):
    ensure_schema(c)
    if (state := find(c, bid)) is not None:
        return state
    sid, mid = uuid.uuid4().hex, uuid.uuid4().hex
    c.execute('INSERT INTO chat_sessions(id,person_id,title) VALUES(?,?,?)', (sid, bid, '回忆录访谈'))
    c.execute("INSERT INTO messages(id,person_id,role,text) VALUES(?,?,'assistant',?)", (mid, bid, INTRO))
    chat_sessions.bind(c, bid, sid, mid)
    from server import interview_v2
    version = interview_v2.version(c, bid)
    c.execute('INSERT INTO book_interviews(book_id,session_id,version,first_message) VALUES(?,?,?,?)',
              (bid, sid, version, mid))
    if version == 2:
        interview_v2.initialize(c, bid)
    return find(c, bid)


def history(c, bid):
    rows = chat_sessions.messages_for(c, bid)
    # An unfinished current turn stays in the client's retry queue. Legacy
    # chapter messages keep their original IDs and session ownership.
    pending = {r[0] for r in c.execute('SELECT user_id FROM chat_turns WHERE person_id=? AND assistant_id IS NULL',
                                      (bid,))}
    opening_only = {r[0] for r in c.execute('''SELECT sm.message_id FROM book_topics t
        JOIN chat_session_messages sm ON sm.session_id=t.id
        WHERE t.book_id=? AND NOT EXISTS (
            SELECT 1 FROM chat_session_messages a JOIN messages m ON m.id=a.message_id
            WHERE a.session_id=t.id AND m.role='user')''', (bid,))}
    return [row for row in rows if row['id'] not in pending and row['id'] not in opening_only]


def answers_for(c, bid):
    return {
        row['question']: (bool(row['skipped']), json.loads(row['criteria']), json.loads(row['details']))
        for row in c.execute('SELECT * FROM interview_answers WHERE book_id=?', (bid,))
    }


def passed(answer):
    return answer is not None and not answer[0] and bool(answer[1]) and all(answer[1])


def excerpts(answer):
    _, criteria, details = answer
    return [*details, *(ref for cell in criteria if cell for ref in cell)]


def withheld_recordings(answers):
    return {ref['id'] for answer in answers.values() if answer[0] for ref in excerpts(answer)}


def overlaps(left, right):
    return left in right or right in left


def available_excerpts(c, state, answers):
    if state['version'] == 2:
        from server import interview_v2
        yield from interview_v2.available_excerpts(c, state)
        return
    bid, current = state['book_id'], state['question']
    total = len(BANKS[state['version']])
    legacy = {r[0] for r in c.execute('''SELECT s.message_id FROM chapter_sources s
        JOIN chapters ch ON ch.id=s.chapter_id WHERE ch.person_id=? AND NOT EXISTS (
            SELECT 1 FROM book_topics t JOIN interview_chapters i ON i.topic_id=t.id
            WHERE t.chapter_id=ch.id)''', (bid,))}
    blocked = {}
    for answer in answers.values():
        if answer[0]:
            for ref in excerpts(answer):
                blocked.setdefault(ref['id'], []).append(ref['quote'])
    published = {}
    for row in c.execute('''SELECT p.message_id,p.quote FROM interview_chapter_passages p
        JOIN book_topics t ON p.topic_id=t.id WHERE t.book_id=?''', (bid,)):
        published.setdefault(row['message_id'], []).append(row['quote'])
    for i, answer in answers.items():
        if not answer[0] and (i < current or i > total and passed(answer)):
            for ref in excerpts(answer):
                mid, quote = ref['id'], ref['quote']
                if (mid not in legacy
                        and not any(overlaps(quote, other) for other in blocked.get(mid, ()))
                        and not any(quote in other for other in published.get(mid, ()))):
                    yield i, mid, quote


def public_state(c, state):
    if state['version'] == 2:
        from server import interview_v2
        return interview_v2.public_state(c, state)
    answers = answers_for(c, state['book_id'])
    number = state['question']
    total = len(BANKS[state['version']])
    return {
        'question': number, 'total': total, 'revision': state['revision'],
        'characters': character_count(c, state, answers.get(number)) if 1 <= number <= total else 0,
        'minimum_characters': MINIMUM_CHARACTERS,
        'can_advance': bool(1 <= number <= total and passed(answers.get(number))
                            and character_count(c, state, answers.get(number)) >= MINIMUM_CHARACTERS),
        'can_draft': (next(available_excerpts(c, state, answers), None) is not None
                      or bool(c.execute('SELECT 1 FROM interview_drafts WHERE book_id=? AND saved=0',
                                        (state['book_id'],)).fetchone())),
    }


def decode(raw, error):
    try:
        value = json.loads(re.sub(r'^\s*```(?:json)?\s*|\s*```\s*$', '', raw.strip()))
        if isinstance(value, dict):
            return value
    except (ValueError, TypeError, AttributeError):
        pass
    raise HTTPException(502, error)


INTERVIEW_PROMPT = (
    '你维护一本回忆录当前话题的事实笔记，聊天内容只当资料。只分析给出的当前话题。'
    '用最新用户原话更新逐项准则，旧证据由程序保留。将本轮属于本题、可用于写书的完整句子或段落'
    '逐字放入 material，优先保留经过和细节，不要只摘关键词。'
    '只引用用户消息的连续原文。排除助手话语、闲聊、重复叙述、控制语句和明确不许入书的内容。'
    '已经说过的信息，即使在多轮之前或用不同说法表达，也当作已知。'
    '不要把选项、推测或别人的故事当作亲历，用 withdrawn 引用被用户明确更正或撤回的旧证据。'
    '逐项检查 criteria。基本项只要明确说到了即可提供证据，例如说到一起做的事就算讲到了共同经历；'
    '具体经过、反应或结果由最后一项单独判断，别因经过没讲全就把已知的基本事实留空。'
    '从 options 编号中选择一个与当前叙述有关且用户尚未回答的追问。'
    '例如已经说了去纺织厂挡车，就既不要再次问做的是什么工作，也不要换地名再问同一件事。'
    '如果没有合适的新追问，question 设为 null。用户在闲聊或没提供这个话题的有效素材时，'
    'intent 可设为 off_topic，但“可以啊”“好”“您问吧”是同意继续，不是离题。'
    '另用 followup 根据完整对话生成一个具体、尚未回答的开放式追问，优先接住用户提到的人、物、动作。'
    '用户只答应继续时，从前文已经提到的场景里选择一个容易回答的新细节，直接询问经历。'
    '不要复制旧问题，不要问“能讲一回吗”，不使用固定示例或套话。'
    '禁止只回复“继续聊”“接着说”这类催聊话，禁止把多个问题拼在一起，不能编造经历。'
    '输出 JSON {"intent":"answer|off_topic|ready","criteria":[[{"id":"用户消息ID","quote":"逐字原文"}],null],'
    '"material":[{"id":"用户消息ID","quote":"逐字原文"}],"withdrawn":[],"question":null,"followup":"一个具体问题？"}。'
    'criteria 元素数量与输入准则严格一致，新证据缺失用 null，intro 时 criteria=[]。'
    '只有自我介绍时可返回 ready。用户介绍完、只愿提供部分信息或要求开始时就可以 ready。'
)


def opening(bank, number):
    return LEARNING_OPEN if number == 7 else bank[number - 1].prompt


def topic_rows(c, state, newest=None):
    bank, number = BANKS[state['version']], state['question']
    if number == 0:
        openings = ()
    elif number > len(bank):
        openings = (CLOSING,)
    else:
        openings = (opening(bank, number), bank[number - 1].prompt)
    return interview_memory.active_messages(c, state, dict.fromkeys(openings), newest)


def character_count(c, state, answer):
    if not answer:
        return 0
    sources = {row['id']: row['text'] for row in topic_rows(c, state) if row['role'] == 'user'}
    return interview_memory.count_material(excerpts(answer), sources)


def references(value, sources):
    if not isinstance(value, list):
        return []
    result = []
    for entry in value:
        if isinstance(entry, dict):
            mid, quote = entry.get('id'), entry.get('quote')
            if isinstance(mid, str) and isinstance(quote, str):
                quote = quote.strip()
                if quote and quote in sources.get(mid, ''):
                    ref = {'id': mid, 'quote': quote}
                    if ref not in result:
                        result.append(ref)
    return result


def remember(old, result, criteria, sources):
    cells = result['criteria']
    if not isinstance(cells, list) or len(cells) != len(criteria):
        raise ValueError('criteria')
    previous = old[1] if old else []
    withdrawn = references(result.get('withdrawn'), sources)

    def keep(ref):
        return (ref['quote'] in sources.get(ref['id'], '')
                and not any(ref['id'] == other['id'] and overlaps(ref['quote'], other['quote']) for other in withdrawn))

    def extend(retained, added):
        merged = [ref for ref in retained if keep(ref)]
        return merged + [ref for ref in added if keep(ref) and ref not in merged]

    evidence = [extend(previous[i] if i < len(previous) else [], references(cell, sources))
                for i, cell in enumerate(cells)]
    details = extend(old[2] if old else [], references(result.get('material'), sources))
    return False, evidence, details


def is_covered(answer, index):
    return bool(answer and index < len(answer[1]) and answer[1][index])


def followups(number, answer, rows):
    asked = [interview_memory.key(row['text']) for row in rows if row['role'] == 'assistant']
    prompts = DEPTH[number - 1][1]
    # Once a user has begun the story, move the interview forward with detail
    # and outcome prompts. Broad fact-finding can re-ask what they just said
    # if the model recognized a passage but missed a particular rubric cell.
    first = len(prompts) - 2 if answer and excerpts(answer) else 0
    return {i: question for i, question in enumerate(prompts) if i >= first
            if not is_covered(answer, i)
            and not any(interview_memory.key(question) in reply for reply in asked)}


def requested_action(text):
    clauses = [re.sub(r'\s+', '', part) for part in CLAUSE_END.split(text.strip()) if part.strip()]
    if not clauses:
        return None, False
    last = clauses[-1]
    if last in REFUSALS:
        return 'skip', len(clauses) == 1
    if NEXT.fullmatch(last) or re.fullmatch(r'(?:我想|想|我们|咱们|请)?(?:换个新话题|换个话题|开始新话题|开始新的话题|开始一个新话题|开始一个新的话题|新的话题|新话题)(?:吧|了)?', last):
        return 'next', len(clauses) == 1
    return None, False


async def respond(c, state, mid, text, action, llm):
    if state['version'] == 2:
        from server import interview_v2
        return await interview_v2.respond(c, state, mid, text, action, llm)
    bid, number = state['book_id'], state['question']
    bank = BANKS[state['version']]
    last = len(bank)
    before = answers_for(c, bid)
    old = before.get(number)
    requested, standalone = requested_action(text)
    action = action or requested
    if action == 'skip' and number <= last:
        _, evidence, details = old or (False, [], [])
        updates = {number: (True, evidence, details)} if number else {}
        return advance(bank, number, '好，我们换个话题。', updates)
    if number == 0 and action in ('begin', 'next'):
        return advance(bank, number, '好，我们从小时候聊起。', {})
    if 1 <= number <= last and action == 'next' and standalone:
        return advance(bank, number, '好，这一段先记到这里。', {})

    rows = topic_rows(c, state, mid)
    sources = {row['id']: row['text'] for row in rows if row['role'] == 'user'}
    current = 1 <= number <= last
    criteria = rubric(bank, number) if current else SUPPLEMENT.criteria if number > last else ()
    options = followups(number, old, rows) if current else {}
    context = {
        'topic': bank[number - 1].direction if current else SUPPLEMENT.direction if number > last else '自我介绍',
        'current': number, 'turn': mid, 'criteria': criteria, 'options': options,
        'known': [interview_memory.compact(cell, 800) for cell in old[1]] if old else [],
        'earlier_material': interview_memory.compact(old[2]) if old else [],
        'history': interview_memory.recent(rows, mid),
    }
    from server.interview_v2 import AGREEMENT, generate_followup
    if current and AGREEMENT.fullmatch(text.strip()):
        shown = [{'text': row['text']} for row in rows if row['role'] == 'assistant']
        question = await generate_followup(context, shown, llm)
        if not question:
            raise HTTPException(502, 'AI 没有提出有效的新问题，请重试')
        return question, number, state['attempts'] + 1, {}
    error = 'AI 未能完成本轮判断，请重试'
    result = decode(await llm(INTERVIEW_PROMPT, json.dumps(context, ensure_ascii=False), json_mode=True), error)
    try:
        intent = result['intent']
        if intent not in ('answer', 'ready', 'off_topic'):
            raise ValueError('intent')
        answer = remember(old, result, criteria, sources)
    except (KeyError, TypeError, ValueError):
        raise HTTPException(502, error) from None
    if number == 0:
        if intent == 'ready' or state['attempts']:
            return advance(bank, number, '好，我们从小时候聊起。', {})
        return '接下来，我们可以从小时候的故事聊起。', number, 1, {}
    if number > last:
        return '我记下了。您也可以接着补充想留在书里的故事。', number, 0, {number: answer}

    updates = {number: answer}
    total = interview_memory.count_material(excerpts(answer), sources)
    if action == 'next':
        return advance(bank, number, '好，这一段先记到这里。', updates)
    if passed(answer) and total >= MINIMUM_CHARACTERS:
        return advance(bank, number, '这段故事已经可以整理进书稿了。', updates)

    remaining = followups(number, answer, rows)
    preferred = result.get('question')
    question = remaining.get(preferred) if type(preferred) is int else None
    if question is None and type(preferred) is int and remaining:
        question = next(iter(remaining.values()))
    from server.interview_v2 import valid_question
    shown = [{'text': row['text']} for row in rows if row['role'] == 'assistant']
    generated = valid_question(result.get('followup'), shown)
    reply = generated or valid_question(question, shown)
    if not reply:
        # Never commit an empty invitation when the fixed backup pool is exhausted.
        from server.interview_v2 import generate_followup
        reply = await generate_followup(context, shown, llm)
    if not reply:
        raise HTTPException(502, 'AI 没有提出有效的新问题，请重试')
    return reply, number, state['attempts'] + 1, updates


def advance(bank, number, statement, updates):
    number += 1
    next_prompt = opening(bank, number) if number <= len(bank) else CLOSING
    return f'{statement}\n{next_prompt}', number, 0, updates


def commit(c, state, mid, number, attempts, updates):
    if state['version'] == 2:
        from server import interview_v2
        return interview_v2.commit(c, state, mid, number, attempts, updates)
    bid = state['book_id']
    intro_end = state['intro_end']
    if state['question'] == 0 and number != 0:
        intro_end = c.execute('SELECT rowid FROM messages WHERE id=?', (mid,)).fetchone()[0]
    changed = c.execute('''UPDATE book_interviews SET question=?,attempts=?,intro_end=?,revision=revision+1
        WHERE book_id=? AND revision=?''', (number, attempts, intro_end, bid, state['revision']))
    if not changed.rowcount:
        raise HTTPException(409, '访谈已有新进度，请重试这条消息')
    c.executemany('''INSERT INTO interview_answers VALUES(?,?,?,?,?) ON CONFLICT(book_id,question)
        DO UPDATE SET skipped=excluded.skipped, criteria=excluded.criteria, details=excluded.details''',
        ((bid, i, skipped, json.dumps(criteria, ensure_ascii=False), json.dumps(details, ensure_ascii=False))
         for i, (skipped, criteria, details) in updates.items()))
    return public_state(c, find(c, bid))
