# Task: Implement Valkey Application Patterns with GLIDE Node.js

You are working on a Node.js TypeScript project that uses the `@valkey/valkey-glide` client library to interact with a 3-node Valkey cluster running in Docker (ports 7000-7002).

The project skeleton is already set up with dependencies installed. Your job is to implement 4 features in `src/app.ts`. Each function has a TODO comment describing what to implement.

## Features to Implement

### A. Cluster-Wide Key Scanner (`scanAllKeys`)
Implement a function that uses SCAN to iterate across all nodes in the cluster, collecting keys matching a glob pattern. Must use GLIDE's cluster-aware scan (ClusterScanCursor) - do NOT use the KEYS command.

### B. Atomic Check-and-Increment with HEXPIRE (`atomicIncrWithExpire`)
Implement a Lua script that atomically:
1. Checks if a hash field exists
2. If it exists, increments its value by 1
3. If it does not exist, sets it to 1
4. Sets a per-field TTL using HEXPIRE (Valkey 9.0+ feature)
5. Returns the new value

Use GLIDE's `Script` class and `invokeScript()` to execute the Lua script.

### C. Sliding Window Rate Limiter (`checkRateLimit`)
Implement a rate limiter that uses hash field expiration (HSETEX or HEXPIRE) for a sliding window approach:
- Each request is tracked as a hash field with a timestamp-based key
- Old entries expire automatically via per-field TTL
- Count active (non-expired) fields to determine if the rate limit is exceeded
- Return whether the request is allowed and how many requests remain

This should use Valkey 9.0+ hash field TTL features (HSETEX, HEXPIRE, HLEN, or similar).

### D. Sharded Pub/Sub Notification System (`setupShardedPubSub`)
Implement a pub/sub system using sharded channels (SSUBSCRIBE/SPUBLISH) - a Valkey 7.0+ feature that routes messages through the cluster's hash slot mechanism:
- Create a subscriber client with sharded channel subscriptions
- Wire up the message handler callback
- Use `PubSubChannelModes.Sharded` for slot-scoped pub/sub

## Requirements

- Use `GlideClusterClient` for all operations (not `GlideClient`)
- Use `@valkey/valkey-glide` APIs - do NOT import redis, ioredis, or other client libraries
- Leverage Valkey 9.0+ features: HSETEX, HEXPIRE for hash field TTL
- Use sharded pub/sub (SPUBLISH) for the notification system
- All functions must be properly typed with TypeScript

## Validation

Run the test suite to verify your implementation:

```bash
npm test
```

All 9 test cases must pass.
