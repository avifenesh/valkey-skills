## Task 6: redis-py to GLIDE Python Migration

### Evaluation Focus

**API mapping accuracy** (high weight)
- redis.asyncio.Redis replaced with GlideClient (standalone) or GlideClusterClient
- GlideClientConfiguration used with NodeAddress for connection
- pipeline() replaced with Batch(is_atomic=False) and client.exec()
- register_script/EVALSHA replaced with Script class and invoke_script()
- pubsub object replaced with GLIDE subscription model (static or dynamic)
- zadd, zrevrange(withscores=True), zrangebyscore(withscores=True) mapped to GLIDE equivalents
- delete(*keys) and exists(*keys) converted to list argument form

**GLIDE-specific patterns** (medium weight)
- Correct use of Batch class with is_atomic flag
- Script class instantiated once and invoked via client.invoke_script()
- Proper GLIDE pubsub approach - either static (PubSubSubscriptions at config time) or dynamic (subscribe/get_pubsub_message)
- Return type handling: GLIDE returns bytes, decoded appropriately
- Sorted set range queries use RangeByIndex or RangeByScore with proper bound objects

**Test preservation** (high weight)
- All 8 tests pass without modification to test_app.py
- conftest.py creates GlideClient fixture with proper async lifecycle (create/close)
- pubsub_client fixture creates a separate GLIDE client suitable for subscriptions
- requirements.txt lists valkey-glide instead of redis

**Async handling** (medium weight)
- All async def functions preserved
- await used for all GLIDE client calls
- Client creation uses await GlideClient.create(config) pattern
- Client shutdown uses await client.close()
- No sync-to-async or async-to-sync regressions
