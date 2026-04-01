"""Pytest fixtures - redis.asyncio client for all tests."""

import pytest_asyncio
import redis.asyncio as aioredis


@pytest_asyncio.fixture
async def client():
    """Primary client for commands and assertions."""
    r = aioredis.Redis(host="localhost", port=6407, decode_responses=False)
    yield r
    await r.aclose()


@pytest_asyncio.fixture
async def pubsub_client():
    """Separate client for pub/sub subscriber (dedicated connection)."""
    r = aioredis.Redis(host="localhost", port=6407, decode_responses=False)
    yield r
    await r.aclose()
