"""Local embeddings endpoint. Bind to loopback; no conversation text is logged."""
import os
from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field


@asynccontextmanager
async def lifespan(app):
    from fastembed import TextEmbedding

    app.state.model = TextEmbedding(
        model_name='BAAI/bge-small-zh-v1.5',
        cache_dir=os.getenv('LIFEPAGES_EMBEDDING_CACHE'),
        threads=2,
    )
    # Load the model before accepting requests to keep cold starts off the chat path.
    list(app.state.model.embed(['预热']))
    yield


app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None, lifespan=lifespan)


class Batch(BaseModel):
    texts: list[str] = Field(min_length=1, max_length=16)


@app.post('/embed')
def embed(batch: Batch):
    if any(not text.strip() or len(text) > 4000 for text in batch.texts):
        raise HTTPException(400, 'Invalid embedding input')
    vectors = app.state.model.embed(batch.texts, batch_size=16)
    return {'vectors': [vector.tolist() for vector in vectors]}
