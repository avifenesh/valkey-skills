## Task-Specific Criteria: Valkey App Patterns (GLIDE Node.js)

### Correct GLIDE API Usage (weight: high)
- Uses `GlideClusterClient.createClient()` with proper address configuration
- Uses `ClusterScanCursor` for cluster-wide SCAN iteration (not raw SCAN commands)
- Uses GLIDE `Script` class with `invokeScript()` for Lua execution (not `customCommand(["EVAL", ...])`)
- Uses `GlideClusterClientConfiguration.PubSubChannelModes.Sharded` for sharded pub/sub
- Properly releases Script objects after use
- Pub/sub subscriptions declared at client creation time (Node.js GLIDE does not support runtime subscribe)

### Cluster Awareness (weight: high)
- All operations use cluster-compatible client and methods
- SCAN iterates across all cluster nodes (not just one)
- Lua script keys map to the same hash slot (KEYS[1] only)
- Sharded pub/sub correctly routes through hash slots

### Valkey 9.0+ Features (weight: high)
- **HEXPIRE**: Used in Lua script for per-field TTL on hash fields
- **HSETEX**: Used in rate limiter for atomic set-with-TTL on hash fields
- These are Valkey-specific commands not available in Redis - their correct usage demonstrates knowledge of the Valkey ecosystem

### Code Quality (weight: medium)
- Proper TypeScript types on all functions
- Async/await used correctly throughout
- Error handling present (try/catch, resource cleanup)
- No memory leaks (Script objects released, clients closed)
- Clean separation of concerns between the 4 features

### Known Pitfalls to Check
- Using `KEYS` command instead of SCAN (blocks the server)
- Using `EXPIRE` on the whole key instead of `HEXPIRE` on individual fields
- Using `GlideClient` instead of `GlideClusterClient`
- Using ioredis or redis imports instead of @valkey/valkey-glide
- Attempting runtime subscribe() in Node.js (not supported - must be at client creation)
- Not handling the cursor loop correctly (forgetting to check `isFinished()`)
