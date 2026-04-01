"""Tests for the async application. All tests run against a real Valkey instance."""

import asyncio

import pytest
import pytest_asyncio

from app import (
    atomic_counter,
    batch_get,
    batch_set,
    crud_delete,
    crud_exists,
    crud_get,
    crud_set,
    leaderboard_add,
    leaderboard_range_by_score,
    leaderboard_top,
    subscribe_and_collect,
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

async def _flush(client):
    """Flush the database to ensure test isolation."""
    await client.flushdb()


# ---------------------------------------------------------------------------
# Test: Basic CRUD
# ---------------------------------------------------------------------------

@pytest.mark.asyncio
async def test_crud_operations(client):
    await _flush(client)

    assert await crud_set(client, "name", "alice") is True
    assert await crud_get(client, "name") == "alice"
    assert await crud_exists(client, "name") == 1
    assert await crud_delete(client, "name") == 1
    assert await crud_get(client, "name") is None
    assert await crud_exists(client, "name") == 0


@pytest.mark.asyncio
async def test_crud_set_with_ttl(client):
    await _flush(client)

    assert await crud_set(client, "temp", "data", ttl=1) is True
    assert await crud_get(client, "temp") == "data"
    await asyncio.sleep(1.5)
    assert await crud_get(client, "temp") is None


# ---------------------------------------------------------------------------
# Test: Pipeline Batching
# ---------------------------------------------------------------------------

@pytest.mark.asyncio
async def test_batch_set_and_get(client):
    await _flush(client)

    mapping = {"k1": "v1", "k2": "v2", "k3": "v3"}
    results = await batch_set(client, mapping)
    assert all(r is True or r == "OK" or r == b"OK" for r in results)

    values = await batch_get(client, ["k1", "k2", "k3"])
    assert values == ["v1", "v2", "v3"]


# ---------------------------------------------------------------------------
# Test: Pub/Sub
# ---------------------------------------------------------------------------

@pytest.mark.asyncio
async def test_pubsub(client, pubsub_client):
    await _flush(client)

    channel = "test-channel"
    expected = ["msg-1", "msg-2", "msg-3"]

    collect_task = asyncio.create_task(
        subscribe_and_collect(pubsub_client, channel, max_messages=3, timeout=10.0)
    )

    # Give subscriber time to register
    await asyncio.sleep(0.5)

    for msg in expected:
        await client.publish(channel, msg)
        await asyncio.sleep(0.1)

    received = await collect_task
    assert received == expected


# ---------------------------------------------------------------------------
# Test: Lua Scripting
# ---------------------------------------------------------------------------

@pytest.mark.asyncio
async def test_atomic_counter(client):
    await _flush(client)

    key = "counter:test"
    assert await atomic_counter(client, key, ttl=10) == 1
    assert await atomic_counter(client, key, ttl=10) == 2
    assert await atomic_counter(client, key, ttl=10) == 3

    # Verify TTL was set
    remaining = await client.ttl(key)
    assert 0 < remaining <= 10


@pytest.mark.asyncio
async def test_atomic_counter_expiry(client):
    await _flush(client)

    key = "counter:expire"
    await atomic_counter(client, key, ttl=1)
    assert await crud_get(client, key) == "1"
    await asyncio.sleep(1.5)
    assert await crud_get(client, key) is None


# ---------------------------------------------------------------------------
# Test: Sorted Set Leaderboard
# ---------------------------------------------------------------------------

@pytest.mark.asyncio
async def test_leaderboard_top(client):
    await _flush(client)

    board = "scores"
    entries = {"alice": 100.0, "bob": 250.0, "carol": 175.0, "dave": 50.0}
    added = await leaderboard_add(client, board, entries)
    assert added == 4

    top3 = await leaderboard_top(client, board, count=3)
    assert len(top3) == 3
    assert top3[0] == ("bob", 250.0)
    assert top3[1] == ("carol", 175.0)
    assert top3[2] == ("alice", 100.0)


@pytest.mark.asyncio
async def test_leaderboard_range_by_score(client):
    await _flush(client)

    board = "scores:range"
    entries = {"alice": 100.0, "bob": 250.0, "carol": 175.0, "dave": 50.0}
    await leaderboard_add(client, board, entries)

    in_range = await leaderboard_range_by_score(client, board, 100.0, 200.0)
    members = [name for name, _ in in_range]
    assert "alice" in members
    assert "carol" in members
    assert "bob" not in members
    assert "dave" not in members
