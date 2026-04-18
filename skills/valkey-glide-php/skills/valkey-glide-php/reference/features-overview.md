# PHP Client Overview

Use when checking GLIDE PHP capabilities, limitations, and install options.

## Status

**GA** - v1.0.0 (2026-01-28). Synchronous blocking native C extension. PHPRedis-compatible class aliases via opt-in `registerPHPRedisAliases()`.

## Requirements

- PHP **8.2 or 8.3** (not 8.1, not 8.4)
- Valkey 7.2+ / Redis 6.2+
- Pre-built binaries for Ubuntu 20+ (x86_64, arm64) and macOS 14.7+ (Apple Silicon)

## Installation

```bash
# PIE (preferred)
pie install valkey-io/valkey-glide-php:1.0.0

# PECL
pecl install https://github.com/valkey-io/valkey-glide-php/releases/download/v1.0.0/valkey_glide-1.0.0.tgz

# Composer
composer require valkey-io/valkey-glide-php
```

After PECL install, enable in `php.ini`:
```ini
extension=valkey_glide
```

## Command groups

Same groups as PHPRedis plus GLIDE additions. Method names follow PHPRedis camelCase (`hSet`, `zAdd`, `sAdd`) per the stub - not snake_case.

| Group | Examples |
|-------|----------|
| String | `set`, `get`, `incr`, `incrBy`, `mget`, `mset`, `getDel`, `getEx` |
| Hash | `hSet`, `hGet`, `hGetAll`, `hDel`, `hMGet`, `hScan` |
| List | `lPush`, `rPush`, `lPop`, `rPop`, `lRange`, `blPop` |
| Set | `sAdd`, `sMembers`, `sIsMember`, `sInter`, `sUnion` |
| Sorted Set | `zAdd`, `zScore`, `zRange`, `zRangeByScore`, `bzPopMin` |
| Stream | `xAdd`, `xRead`, `xReadGroup`, `xAck`, `xClaim`, `xAutoClaim` |
| PubSub | `subscribe`, `publish`, `psubscribe` (no `ssubscribe` yet) |
| Bitmap | `setBit`, `getBit`, `bitCount`, `bitOp`, `bitPos` |
| HyperLogLog | `pfAdd`, `pfCount`, `pfMerge` |
| Geo | `geoAdd`, `geoSearch`, `geoDist` |
| Scripting | `eval`, `evalSha`, `eval_ro`, `evalSha_ro` |
| Functions | `function`, `fcall`, `fcall_ro` |
| Generic | `del`, `exists`, `expire`, `ttl`, `type`, `scan` |
| Server | `info`, `dbSize`, `flushDB`, `config` |
| Connection | `ping`, `echo`, `select`, `auth`, `client` |
| Transactions | `multi`, `discard`, `watch`, `unwatch`, `pipeline` |

## Features matrix

| Feature | Available | Notes |
|---------|-----------|-------|
| Standalone mode | Yes | `ValkeyGlide` class; `new` + `connect()` |
| Cluster mode | Yes | `ValkeyGlideCluster` class; config in constructor |
| TLS | Yes | `use_tls: true` |
| Auth - password / ACL | Yes | `credentials: ['username' => ..., 'password' => ...]` |
| Auth - IAM (AWS) | Yes | `credentials: ['username' => ..., 'iamConfig' => [...]]`. Requires `use_tls: true`. |
| PubSub (exact, pattern) | Yes | Array+callback form only |
| Sharded PubSub | **No** | `ssubscribe` is a TODO stub in v1.0.0 |
| Batching - atomic (MULTI) | Yes | See Batching section below |
| Batching - pipeline | Yes | See Batching section below |
| WATCH | Yes | `$client->watch(...)` |
| Cluster scan | Yes | Unified iteration across shards |
| Multi-slot commands | Yes | MGET/MSET/DEL across slots |
| AZ Affinity | Yes | `read_from: 2` with `client_az` |
| PHPRedis aliases | Yes | Opt-in via `ValkeyGlide::registerPHPRedisAliases()` |
| Lazy connect | Yes | `lazy_connect: true` |
| Password rotation | Yes | `updateConnectionPassword()` / `clearConnectionPassword()` |
| OpenTelemetry | Yes | `advanced_config: ['otel' => OpenTelemetryConfig::builder()...]` |
| Compression | Experimental | Not production-ready |
| Async API | **No** | PHP's execution model is synchronous |

## Batching

Three shapes, all ending in a call to `$client->` plus the `exec` method:

```php
// Atomic transaction
$client->multi(ValkeyGlide::MULTI);
$client->set('a', '1');
$client->incr('a');
$results = $client->exec();

// Pipeline (non-atomic, higher throughput)
$client->pipeline()
    ->set('a', '1')
    ->incr('a')
    ->exec();

// Optimistic locking - exec() returns null if the watched key changed
$client->watch(['key']);
$client->multi(ValkeyGlide::MULTI);
$client->set('key', $newValue);
$results = $client->exec();
```

## Error handling

```php
try {
    $value = $client->get('key');
} catch (ValkeyGlideException $e) {
    // Single exception class - no subtype hierarchy.
    // Inspect $e->getMessage() to classify (WRONGTYPE, timeout, connection, NOAUTH, etc.).
    error_log($e->getMessage());
}
```

Under `ValkeyGlide::registerPHPRedisAliases()` the same instances satisfy `catch (RedisException $e)`.

## Password rotation without reconnect

```php
$client->updateConnectionPassword('new-secret', immediateAuth: false);
$client->clearConnectionPassword(immediateAuth: false);
```

Set `immediateAuth: true` to re-authenticate immediately rather than lazily on the next command.

## Limitations

- **No Windows, no Alpine/MUSL.** Glibc-based Linux only.
- **No async API.**
- **No sharded PubSub** in v1.0.0.
- **Compression is experimental.**
- **No Laravel/Symfony framework integration** bundled. PHPRedis aliases may enable it but it is untested.

## Repository

`valkey-io/valkey-glide-php` (separate repo from the main GLIDE monorepo). Package: `valkey-io/valkey-glide-php` on Packagist.
