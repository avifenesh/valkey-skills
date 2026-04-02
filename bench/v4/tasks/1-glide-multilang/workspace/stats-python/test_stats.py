"""Tests for the StatsService using GLIDE client APIs.

Validates GLIDE-specific patterns:
- Uses GlideClient, not redis.Redis
- Uses Batch, not .pipeline()
- Uses invoke_script/Script for Lua scripting
- All operations are async
"""

import pytest
import pytest_asyncio
from glide import GlideClient, GlideClientConfiguration, NodeAddress

from stats import StatsService


@pytest_asyncio.fixture
async def client():
    """Create a GLIDE standalone client for testing."""
    config = GlideClientConfiguration(
        addresses=[NodeAddress("localhost", 6379)],
    )
    c = await GlideClient.create(config)
    yield c
    await c.close()


@pytest_asyncio.fixture
async def stats(client: GlideClient):
    """Create a StatsService and clean up test keys before/after."""
    svc = StatsService(client)
    # Clean up test keys
    cursor = "0"
    while True:
        result = await client.scan(cursor, match="stats:*", count=100)
        cursor_next = result[0]
        keys = result[1]
        if keys:
            await client.delete(keys)
        if cursor_next == b"0":
            break
        cursor = cursor_next
    yield svc


@pytest.mark.asyncio
async def test_record_event(stats: StatsService, client: GlideClient):
    """Test that record_event stores data in a hash and pushes to the type list."""
    event_id = await stats.record_event("click", {"url": "/home", "user": "alice"})

    assert event_id is not None
    assert "click" in event_id

    # Verify the hash was stored
    event_data = await client.hgetall(f"stats:event:{event_id}")
    assert event_data is not None
    assert event_data[b"url"] == b"/home"
    assert event_data[b"type"] == b"click"

    # Verify the event ID was pushed to the type list
    list_len = await client.llen("stats:events:click")
    assert list_len >= 1


@pytest.mark.asyncio
async def test_compute_daily_stats(stats: StatsService, client: GlideClient):
    """Test that compute_daily_stats uses Batch to read event counts."""
    # Record some events
    await stats.record_event("click", {"url": "/home"})
    await stats.record_event("click", {"url": "/about"})
    await stats.record_event("view", {"page": "/home"})

    result = await stats.compute_daily_stats()
    assert isinstance(result, dict)
    assert result["click"] == 2
    assert result["view"] == 1
    assert result["purchase"] == 0


@pytest.mark.asyncio
async def test_run_lua_aggregate(stats: StatsService, client: GlideClient):
    """Test that run_lua_aggregate uses Script and invoke_script."""
    # Set up test keys with numeric values
    await client.set("stats:val:a", "10")
    await client.set("stats:val:b", "20")
    await client.set("stats:val:c", "30")

    result = await stats.run_lua_aggregate(
        keys=["stats:val:a", "stats:val:b", "stats:val:c"],
        args=[],
    )
    assert result == 60


@pytest.mark.asyncio
async def test_record_multiple_event_types(stats: StatsService, client: GlideClient):
    """Test recording different event types creates separate lists."""
    await stats.record_event("click", {"url": "/home"})
    await stats.record_event("purchase", {"item": "widget", "amount": "9.99"})

    click_len = await client.llen("stats:events:click")
    purchase_len = await client.llen("stats:events:purchase")

    assert click_len >= 1
    assert purchase_len >= 1


@pytest.mark.asyncio
async def test_uses_glide_client_not_redis(client: GlideClient):
    """Verify we are using GlideClient, not redis-py."""
    assert isinstance(client, GlideClient)
    # GlideClient should not have a .pipeline() method - GLIDE uses Batch
    assert not hasattr(client, "pipeline")
