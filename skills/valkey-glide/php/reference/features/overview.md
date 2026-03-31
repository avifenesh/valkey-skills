# PHP Client Overview

Use when evaluating GLIDE PHP capabilities, understanding differences from PHPRedis, or checking available commands and limitations.

## Contents

- Status (line 19)
- Key Differences from Other GLIDE Clients (line 23)
- Requirements (line 34)
- Platform Support (line 39)
- Installation (line 49)
- Available Command Groups (line 68)
- Features (line 89)
- Error Handling (line 107)
- Architecture Notes (line 126)
- Limitations (line 133)
- Repository (line 141)

## Status

**GA** - version 1.0.0 released. Production-ready.

## Key Differences from Other GLIDE Clients

| Aspect | PHP Client | Python/Java/Node.js Clients |
|--------|-----------|----------------------------|
| Async model | Synchronous (blocking) | Async (asyncio, CompletableFuture, Promise) |
| Extension type | Native C extension | Bindings (ctypes, JNI, N-API) |
| PHPRedis compat | Class name aliases | N/A |
| Installation | PIE / PECL / Composer | pip / Maven / npm |
| Repository | Separate (`valkey-glide-php`) | Monorepo (`valkey-glide`) |
| Platform | Linux, macOS only | Linux, macOS (+ Windows for some) |

## Requirements

- PHP 8.2 or 8.3
- Valkey 7.2+ or Redis 6.2+

## Platform Support

| Platform | Architecture | Supported |
|----------|-------------|-----------|
| Ubuntu 20+ | x86_64 | Yes |
| Ubuntu 20+ | arm64 | Yes |
| macOS 14.7+ | Apple Silicon | Yes |
| Windows | any | No |
| Alpine/MUSL | any | No |

## Installation

```bash
# Via PIE (recommended)
pie install valkey-io/valkey-glide-php:1.0.0

# Via PECL
curl -L https://github.com/valkey-io/valkey-glide-php/releases/download/v1.0.0/valkey_glide-1.0.0.tgz -o valkey_glide-1.0.0.tgz
pecl install valkey_glide-1.0.0.tgz

# Via Composer
composer require valkey-io/valkey-glide-php
```

After PECL installation, add to `php.ini`:
```ini
extension=valkey_glide
```

## Available Command Groups

| Group | Examples | Status |
|-------|----------|--------|
| String | `set`, `get`, `incr`, `incrBy`, `mget`, `mset` | Available |
| Hash | `hset`, `hget`, `hgetall`, `hdel`, `hmset` | Available |
| List | `lpush`, `rpush`, `lpop`, `rpop`, `lrange` | Available |
| Set | `sadd`, `smembers`, `sismember`, `scard` | Available |
| Sorted Set | `zadd`, `zscore`, `zrank`, `zrange`, `zrangebyscore` | Available |
| Stream | `xadd`, `xread`, `xreadgroup`, `xack`, `xgroup` | Available |
| PubSub | `subscribe`, `publish`, `psubscribe` | Available |
| Bitmap | `setbit`, `getbit`, `bitcount`, `bitop` | Available |
| HyperLogLog | `pfadd`, `pfcount`, `pfmerge` | Available |
| Geo | `geoadd`, `geosearch`, `geodist` | Available |
| Scripting | `eval`, `evalsha` | Available |
| Generic | `del`, `exists`, `expire`, `ttl`, `type`, `scan` | Available |
| Server | `info`, `dbsize`, `flushdb`, `config` | Available |
| Connection | `ping`, `echo`, `select`, `auth` | Available |
| Cluster | `cluster info`, `cluster nodes` | Available (cluster client) |
| Batching | Transaction (MULTI/EXEC) and pipeline | Available |

## Features

| Feature | Available | Notes |
|---------|-----------|-------|
| Standalone mode | Yes | Via `ValkeyGlide` |
| Cluster mode | Yes | Via `ValkeyGlideCluster` |
| TLS | Yes | `use_tls: true` parameter |
| Authentication | Yes | Password, ACL, IAM (AWS) |
| PubSub | Yes | Subscribe, psubscribe, publish |
| Batching | Yes | Atomic (MULTI/EXEC) and non-atomic (pipeline) |
| Cluster scan | Yes | Unified key iteration across shards |
| Multi-slot commands | Yes | MGET/MSET/DEL across slots |
| AZ Affinity | Yes | `read_from: 2` with `client_az` |
| PHPRedis aliases | Yes | `ValkeyGlide::registerPHPRedisAliases()` |
| Compression | Experimental | Being expanded |
| OpenTelemetry | In progress | Traces + metrics support |
| Lazy connect | Yes | Defer connection until first command |

## Error Handling

```php
try {
    $value = $client->get('key');
} catch (ValkeyGlideException $e) {
    $msg = $e->getMessage();
    if (str_contains($msg, 'timeout')) {
        echo "Request timed out\n";
    } elseif (str_contains($msg, 'connection')) {
        echo "Connection lost - client is reconnecting\n";
    } else {
        echo "Error: {$msg}\n";
    }
}
```

All errors throw `ValkeyGlideException` (aliased as `RedisException` when PHPRedis aliases are registered).

## Architecture Notes

- Native C extension calling the GLIDE Rust core via `glide-ffi`
- Synchronous blocking API - each command blocks until response
- Single multiplexed connection per node
- Pre-built binaries distributed via PIE, Composer, and PECL

## Limitations

- **No Windows support**
- **No Alpine/MUSL support**
- **No async API** - PHP's execution model is synchronous
- **Compression is experimental** - not yet production-ready
- **No official framework integrations** - PHPRedis aliases may enable use with Laravel's Redis driver but this is untested

## Repository

Separate repo: [valkey-io/valkey-glide-php](https://github.com/valkey-io/valkey-glide-php)

Package: `pie install valkey-io/valkey-glide-php`
