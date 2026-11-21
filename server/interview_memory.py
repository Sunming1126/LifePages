"""Bounded working context and verifiable material for the current topic."""

import re
from collections import defaultdict

CLAUSE_END = re.compile(r'[。！？!?；;\n]+')


def active_messages(c, state, openings, newest=None):
    sid = state['session_id']
    first = c.execute('SELECT rowid FROM messages WHERE id=?', (state['first_message'],)).fetchone()[0]
    boundary = state['intro_end'] or first
    if openings:
        for opening in openings:
            row = c.execute('''SELECT MAX(m.rowid) FROM chat_session_messages sm
                JOIN messages m ON m.id=sm.message_id WHERE sm.session_id=?
                AND m.role='assistant' AND substr(m.text,-length(?))=?''', (sid, opening, opening)).fetchone()
            boundary = max(boundary, row[0] or first)
    return [dict(row) for row in c.execute('''SELECT m.id,m.role,m.text FROM chat_session_messages sm
        JOIN messages m ON m.id=sm.message_id LEFT JOIN chat_turns t ON t.user_id=m.id
        WHERE sm.session_id=? AND m.rowid>? AND m.role IN ('user','assistant')
        AND (t.request_id IS NULL OR t.assistant_id IS NOT NULL OR m.id=?)
        ORDER BY m.rowid''', (sid, boundary, newest))]


def recent(rows, newest):
    selected, remaining = [], 16_000
    for row in reversed(rows[-10:]):
        text = row['text']
        if row['id'] == newest:
            selected.append(row)
            remaining = max(0, remaining - len(text))
        elif remaining:
            selected.append({**row, 'text': text[-remaining:]})
            remaining = max(0, remaining - len(text))
    return list(reversed(selected))


def compact(answers, limit=4000):
    selected = []
    for ref in reversed(answers):
        if limit <= 0:
            break
        if ref not in selected:
            selected.append({**ref, 'quote': ref['quote'][:limit]})
            limit -= len(ref['quote'])
    return list(reversed(selected))


def key(text):
    return ''.join(ch for ch in text.casefold() if ch.isalnum())


def count_material(refs, sources):
    ranges = defaultdict(list)
    for ref in refs:
        text = sources.get(ref['id'], '')
        start = text.find(ref['quote'])
        if start != -1:
            ranges[ref['id']].append((start, start + len(ref['quote'])))
    unique = set()
    for mid, spans in ranges.items():
        merged = []
        for start, end in sorted(spans):
            if merged and start <= merged[-1][1]:
                merged[-1] = (merged[-1][0], max(end, merged[-1][1]))
            else:
                merged.append((start, end))
        for start, end in merged:
            unique.update(filter(None, map(key, CLAUSE_END.split(sources[mid][start:end]))))
    # Different citations can use a short subphrase from an already-counted
    # sentence. Count the larger passage once, even across repeated answers.
    distinct = []
    for passage in sorted(unique, key=len, reverse=True):
        if not any(passage in old for old in distinct):
            distinct.append(passage)
    return sum(map(len, distinct))
