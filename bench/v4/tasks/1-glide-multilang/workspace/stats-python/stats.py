"""Background stats aggregation service using GLIDE batch operations and Lua scripting.

Uses GlideClient (standalone), Batch for multi-command pipelines, and Script/invoke_script
for Lua script invocation. Uses Batch instead of legacy pipeline patterns.
"""

import time
from typing import Any

from glide import (
    Batch,
    GlideClient,
    GlideClientConfiguration,
    NodeAddress,
    Script,
)


class StatsService:
    """Async statistics aggregation service backed by Valkey via GLIDE.

    Key schema:
        stats:event:{event_id}   - HASH with event data fields
        stats:events:{event_type} - LIST of event IDs for each type
    """

    def __init__(self, client: GlideClient) -> None:
        self.client = client
        self.event_prefix = "stats:event:"
        self.list_prefix = "stats:events:"

    async def record_event(self, event_type: str, data: dict[str, str]) -> str:
        """Store event data in a hash and push the event ID to a type-specific list.

        TODO: Implement the following steps:
            1. Generate a unique event ID (e.g., using timestamp + event_type)
            2. Add a "type" field and "timestamp" field to the data dict
            3. HSET the event data to stats:event:{event_id}
            4. LPUSH the event_id onto stats:events:{event_type}

        Returns:
            The generated event ID.
        """
        event_id = f"{event_type}:{int(time.time() * 1000)}"
        # TODO: Store event hash and push to list
        # await self.client.hset(self.event_prefix + event_id, {**data, "type": event_type, "timestamp": str(time.time())})
        # await self.client.lpush(self.list_prefix + event_type, [event_id])
        raise NotImplementedError("TODO: implement record_event")

    async def compute_daily_stats(self) -> dict[str, int]:
        """Use a Batch operation to atomically read multiple event lists and compute counts.

        TODO: Implement the following steps:
            1. Create a Batch(is_atomic=False) for pipelining
            2. Add LLEN commands for known event types (e.g., "click", "view", "purchase")
            3. Run the batch with client and raise_on_error=True
            4. Return a dict mapping event_type to count

        Returns:
            Dictionary mapping event type names to their event counts.
        """
        event_types = ["click", "view", "purchase"]

        batch = Batch(is_atomic=False)
        for event_type in event_types:
            batch.llen(self.list_prefix + event_type)

        # TODO: Run batch and build results dict
        # results = await self.client.exec(batch, raise_on_error=True)
        # return {event_types[i]: results[i] for i in range(len(event_types))}
        raise NotImplementedError("TODO: implement compute_daily_stats")

    async def run_lua_aggregate(self, keys: list[str], args: list[str]) -> Any:
        """Use a Lua script to aggregate values across multiple keys.

        Uses Script class and invoke_script for Lua invocation.
        The script sums numeric values stored at the given keys.

        TODO: Implement the following steps:
            1. Create a Script with Lua code that iterates KEYS and sums their values
            2. Call client.invoke_script(script, keys=keys, args=args)
            3. Return the result

        Args:
            keys: Valkey keys whose values will be aggregated.
            args: Additional arguments passed to the Lua script.

        Returns:
            The aggregated result from the Lua script.
        """
        lua_code = """
        local sum = 0
        for i, key in ipairs(KEYS) do
            local val = redis.call('GET', key)
            if val then
                sum = sum + tonumber(val)
            end
        end
        return sum
        """
        script = Script(lua_code)
        # TODO: Run using invoke_script
        # result = await self.client.invoke_script(script, keys=keys, args=args)
        # return result
        raise NotImplementedError("TODO: implement run_lua_aggregate")


async def create_stats_service(host: str = "localhost", port: int = 6379) -> StatsService:
    """Create a StatsService with a connected GlideClient.

    Example showing the GLIDE configuration pattern for standalone mode.
    """
    config = GlideClientConfiguration(
        addresses=[NodeAddress(host, port)],
    )
    client = await GlideClient.create(config)
    return StatsService(client)
