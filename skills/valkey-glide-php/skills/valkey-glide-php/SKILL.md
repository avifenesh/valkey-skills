---
name: valkey-glide-php
description: "Use when building PHP apps with Valkey GLIDE - native C extension (PHP 8.2/8.3), synchronous blocking API, ValkeyGlide + ValkeyGlideCluster, callback-based subscribe/psubscribe, PHPRedis compatibility aliases, PIE/Composer/PECL install. Assumes PHPRedis knowledge; only GLIDE divergence is documented."
version: 2.1.0
argument-hint: "[API or config question]"
---

# Valkey GLIDE PHP Client

Agent-facing skill for GLIDE PHP. Assumes the reader can already write PHPRedis from training (`new Redis()`, `$r->connect($host, $port)`, positional command args). Covers only what GLIDE diverges on and what GLIDE adds on top.

**Separate repository:** `valkey-io/valkey-glide-php` (v1.0.0 GA).

## Routing

| Question | Reference |
|----------|-----------|
| `ValkeyGlide` vs `ValkeyGlideCluster` construction divergence (standalone needs explicit `connect()`; cluster config goes in `__construct`), TLS, auth, IAM, read_from, reconnect strategy, `registerPHPRedisAliases()` | [connection](reference/features-connection.md) |
| Array-and-callback `subscribe(array, callable)` / `psubscribe(array, callable)` - REVERSED shape from PHPRedis varargs; `ssubscribe` NOT implemented in v1.0.0; `unsubscribe(?array)`; introspection via `pubsub()` | [pubsub](reference/features-pubsub.md) |
| Install via PIE/PECL/Composer, PHP 8.2/8.3 only, supported platforms, command groups, batching (MULTI/EXEC + pipeline), error model (`ValkeyGlideException`), password rotation | [overview](reference/features-overview.md) |

## The #1 agent mistake: subscribe signature

PHPRedis accepts `$r->subscribe(['ch1','ch2'], $callback)` but also legacy forms. GLIDE PHP is strict: **`subscribe(array $channels, callable $cb): bool`** - the array of channels is REQUIRED, the callback is REQUIRED, and there are NO varargs-style overloads. Same for `psubscribe`. See the features-pubsub reference for callback signature.

## Grep hazards

1. **`publish(string $channel, string $message): int` - STANDARD ORDER.** PHP GLIDE does NOT reverse the args (unlike Python, Node.js, Java GLIDE which DO reverse to `publish(message, channel)`). PHP follows PHPRedis convention. No action needed on migration.
2. **`subscribe(array $channels, callable $cb): bool`** - channels MUST be an array even for a single channel. Callback signature: `function ($client, $channel, $message) { }`. Inside the callback you can call `$client->unsubscribe([$channel])` to break out of the subscribe loop.
3. **`psubscribe(array $patterns, callable $cb): bool`** - same shape. Callback signature the same: `function ($client, $channel, $message) { }`. Note PHPRedis pattern callback uses 4 args `($redis, $pattern, $channel, $message)` - GLIDE uses 3 even for pattern subscribes. Silent-bug risk.
4. **`ssubscribe` / `sunsubscribe` / `spublish` NOT IMPLEMENTED in v1.0.0.** The stub has a TODO-commented `ssubscribe` signature. Do not document sharded PubSub as available.
5. **Standalone construction is two-step: `new ValkeyGlide()` then `->connect(addresses: [...])`.** The constructor takes zero arguments. Passing config to `new ValkeyGlide(addresses: [...])` is a type error.
6. **Cluster construction is one-step: `new ValkeyGlideCluster(addresses: [...], use_tls: true, ...)`.** Cluster has a parameterized constructor with 19 positions (7 PHPRedis-style + 12 GLIDE-style). Mixing PHPRedis-style and GLIDE-style positional args throws.
7. **PHP support is 8.2 and 8.3 ONLY.** Not 8.1, not 8.4. The v1.0.0 binaries are built for these two minor versions.
8. **No Windows, no Alpine/MUSL.** Pre-built binaries cover Ubuntu 20+ (x86_64/arm64) and macOS 14.7+ (Apple Silicon).
9. **All errors throw `ValkeyGlideException`.** Single exception class, no hierarchy. Inspect `$e->getMessage()` for text classification (WRONGTYPE, timeout, connection, etc.). Aliased as `RedisException` after `ValkeyGlide::registerPHPRedisAliases()`.
10. **`registerPHPRedisAliases()` is static, returns `bool`.** Creates `Redis -> ValkeyGlide`, `RedisCluster -> ValkeyGlideCluster`, `RedisException -> ValkeyGlideException` aliases. Call once at bootstrap; returns `false` if already registered.
11. **`$client->close()` is mandatory** for deterministic shutdown. The destructor closes automatically but releasing early is preferred for long-running CLI/daemons.
12. **`reconnect_strategy` keys:** `num_of_retries`, `factor`, `exponent_base`, `jitter_percent`. Not `numOfRetries` / `retries` / `backoff`.
13. **Read strategy constants on `ValkeyGlide::`:** `READ_FROM_PRIMARY` (0), `READ_FROM_PREFER_REPLICA` (1), `READ_FROM_AZ_AFFINITY` (2), `READ_FROM_AZ_AFFINITY_REPLICAS_AND_PRIMARY` (3). Passed as `read_from: 2` to `connect()` or cluster constructor.
14. **Password rotation: `updateConnectionPassword()` and `clearConnectionPassword()`** - both take `$immediateAuth = false` flag. Use during secret rotation without client restart.

## Cross-references

- `valkey` skill - Valkey server commands and app patterns
- `glide-dev` skill - GLIDE core internals and FFI binding mechanics
