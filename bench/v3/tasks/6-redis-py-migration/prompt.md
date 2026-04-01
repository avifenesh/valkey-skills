The workspace/ directory contains a working Python application built with redis-py (redis.asyncio). Your task is to migrate it to use the GLIDE Python client (valkey-glide) so that all existing tests pass.

Requirements:

1. Replace all redis-py imports and client usage with GLIDE equivalents.
2. Migrate pipeline batching to GLIDE Batch API.
3. Migrate Pub/Sub to GLIDE subscription model.
4. Migrate Lua script execution to GLIDE Script / invoke_script API.
5. Migrate sorted set operations to GLIDE equivalents (zrange_withscores, RangeByIndex, etc.).
6. Preserve all async/await patterns.
7. Update requirements.txt to use valkey-glide instead of redis.
8. Update conftest.py to create a GLIDE client instead of a redis client.
9. All 8 existing tests must pass against a running Valkey instance on localhost:6379.

Do not change the test file. The tests define the contract - your migration must satisfy them.
