"""Optional private semantic index. SQLite validates all returned candidates."""
import hashlib
import math
import os
import uuid

import httpx


class VectorIndex:
    dimension = 512

    def __init__(self):
        self.url = os.getenv('LIFEPAGES_QDRANT_URL', '').rstrip('/')
        self.embeddings = os.getenv('LIFEPAGES_EMBEDDINGS_URL', 'http://127.0.0.1:8042').rstrip('/')
        self.collection = os.getenv('LIFEPAGES_QDRANT_COLLECTION', 'lifepages_memory_bge_zh_v1')
        self.namespace = os.getenv('LIFEPAGES_MEMORY_NAMESPACE', 'lifepages')
        self.key = hashlib.sha256(f'{self.url}/{self.collection}/{self.namespace}'.encode()).hexdigest()
        token = os.getenv('LIFEPAGES_QDRANT_API_KEY')
        self.headers = {'api-key': token} if token else {}

    @property
    def endpoint(self):
        return f'{self.url}/collections/{self.collection}'

    def scope(self, account, pid):
        return {'namespace': self.namespace, 'account': account, 'person': pid}

    def point_id(self, account, pid, iid):
        return str(uuid.uuid5(uuid.NAMESPACE_URL, f'LifePages/{self.namespace}/{account}/{pid}/{iid}'))

    async def embed(self, client, texts):
        response = await client.post(f'{self.embeddings}/embed', json={'texts': texts})
        response.raise_for_status()
        vectors = response.json()['vectors']
        if len(vectors) != len(texts) or any(
            len(v) != self.dimension or not all(isinstance(x, (float, int)) and math.isfinite(x) for x in v)
            for v in vectors
        ):
            raise ValueError('Invalid embedding response')
        return vectors

    async def ensure(self, client):
        response = await client.get(self.endpoint, headers=self.headers)
        if response.status_code == 404:
            created = await client.put(self.endpoint, headers=self.headers,
                                       json={'vectors': {'size': self.dimension, 'distance': 'Cosine'}})
            if created.status_code != 409:
                created.raise_for_status()
            schema = {}
        else:
            response.raise_for_status()
            schema = response.json()['result']['payload_schema']
        for key in ('namespace', 'account', 'person'):
            if key not in schema:
                response = await client.put(f'{self.endpoint}/index', headers=self.headers, params={'wait': 'true'},
                                            json={'field_name': key, 'field_schema': 'keyword'})
                response.raise_for_status()

    async def search(self, account, pid, text):
        scope = self.scope(account, pid)
        if pid is None:
            del scope['person']
        async with httpx.AsyncClient(timeout=1.2, trust_env=False) as client:
            (vector,) = await self.embed(client, [text[:1200]])
            response = await client.post(f'{self.endpoint}/points/query', headers=self.headers, json={
                'query': vector, 'limit': 12, 'score_threshold': .49, 'with_payload': True,
                'filter': {'must': [{'key': k, 'match': {'value': v}} for k, v in scope.items()]},
            })
            response.raise_for_status()
        return {point['payload']['memory_id']: (point['payload']['revision'], point['score'])
                for point in response.json()['result']['points']
                if all(point['payload'].get(key) == value for key, value in scope.items())}

    async def sync(self, account, pid, rows):
        active = [row for row in rows if row['status'] == 'active']
        removed = [self.point_id(account, pid, row['id']) for row in rows if row['status'] != 'active']
        scope = self.scope(account, pid)
        async with httpx.AsyncClient(timeout=30, trust_env=False) as client:
            await self.ensure(client)
            if removed:
                response = await client.post(f'{self.endpoint}/points/delete', headers=self.headers,
                                             params={'wait': 'true'}, json={'points': removed})
                response.raise_for_status()
            if active:
                texts = [f"{row['title']}\n{row['content']}\n{row['tags']}" for row in active]
                vectors = await self.embed(client, texts)
                response = await client.put(f'{self.endpoint}/points', headers=self.headers, params={'wait': 'true'},
                                            json={'points': [
                    {'id': self.point_id(account, pid, row['id']), 'vector': vector,
                     'payload': {**scope, 'memory_id': row['id'], 'revision': row['revision']}}
                    for row, vector in zip(active, vectors)
                ]})
                response.raise_for_status()
