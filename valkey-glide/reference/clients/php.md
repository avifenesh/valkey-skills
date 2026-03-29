# PHP Client

Use when building PHP applications with Valkey GLIDE - synchronous API via native C extension.

## Installation

**Requirements:** PHP 8.2 - 8.3

**Separate repository:** [valkey-io/valkey-glide-php](https://github.com/valkey-io/valkey-glide-php)

### Via PIE (PHP Installer for Extensions)

```bash
pie install valkey-io/valkey-glide-php
```

### Via Composer

```bash
composer require valkey-io/valkey-glide-php
```

### Via PECL

```bash
pecl install valkey_glide-<version>.tgz
```

After PECL installation, add to `php.ini`:

```ini
extension=valkey_glide
```

**Platform support:** Linux (x86_64, arm64), macOS (Apple Silicon, x86_64). No Windows support.

---

## Client Classes

| Class | Mode | Description |
|-------|------|-------------|
| `ValkeyGlide` | Standalone | Single-node or primary+replicas |
| `ValkeyGlideCluster` | Cluster | Valkey Cluster with auto-topology |

The PHP client provides a synchronous API - all commands block until a response is received.

---

## Standalone Connection

```php
<?php

$client = new ValkeyGlide();
$client->connect(
    addresses: [['host' => 'localhost', 'port' => 6379]]
);

$client->set('greeting', 'Hello from GLIDE');
$value = $client->get('greeting');
echo "Got: {$value}\n";

$client->close();
```

---

## Cluster Connection

```php
<?php

$client = new ValkeyGlideCluster();
$client->connect(
    addresses: [
        ['host' => 'node1.example.com', 'port' => 6379],
        ['host' => 'node2.example.com', 'port' => 6380],
    ]
);

$client->set('key', 'value');
$value = $client->get('key');
echo "Got: {$value}\n";

$client->close();
```

Only seed addresses are needed - GLIDE discovers the full cluster topology automatically.

---

## Configuration

### Connection Options

Configuration is passed as named parameters to the `connect()` method:

```php
$client = new ValkeyGlide();
$client->connect(
    addresses: [['host' => 'localhost', 'port' => 6379]],
    useTLS: true,
    credentials: ['username' => 'myuser', 'password' => 'mypass'],
    requestTimeout: 5000,
    databaseId: 0,
    clientName: 'my-app',
);
```

### TLS

```php
$client->connect(
    addresses: [['host' => 'valkey.example.com', 'port' => 6380]],
    useTLS: true,
);
```

### Authentication

See `features/tls-auth.md` for TLS and authentication details.

```php
$client->connect(
    addresses: [['host' => 'localhost', 'port' => 6379]],
    credentials: [
        'username' => 'myuser',
        'password' => 'mypass',
    ],
);
```

---

### Reconnect Strategy

The PHP client handles reconnection internally. Reconnect backoff configuration options are not yet exposed in the PHP API - the Rust core manages retry behavior automatically.

---

## ReadFrom Strategies

| Value | Behavior |
|-------|----------|
| `PRIMARY` | All reads to primary (default) |
| `PREFER_REPLICA` | Round-robin replicas, fallback to primary |
| `AZ_AFFINITY` | Prefer same-AZ replicas |
| `AZ_AFFINITY_REPLICAS_AND_PRIMARY` | Same-AZ replicas, then primary, then remote |

AZ Affinity strategies require Valkey 8.0+ with the client AZ configured. See `features/az-affinity.md` for detailed AZ routing behavior.

---

## Error Handling

The PHP client throws exceptions on errors. Common exception types:

| Exception | Description |
|-----------|-------------|
| `ValkeyGlideException` | Base exception class |
| Request timeout | When request exceeds configured timeout |
| Connection error | Connection lost (client auto-reconnects) |

```php
try {
    $value = $client->get('key');
} catch (ValkeyGlideException $e) {
    echo "Error: " . $e->getMessage() . "\n";
}
```

---

## Basic Operations

### Strings

```php
$client->set('key', 'value');
$value = $client->get('key');          // "value" or null
$client->set('counter', '0');
$client->incr('counter');              // 1
$client->incrBy('counter', 5);         // 6
```

### Hash

```php
$client->hset('user:1', 'name', 'Alice');
$client->hset('user:1', 'email', 'alice@example.com');
$name = $client->hget('user:1', 'name');  // "Alice"
$all = $client->hgetall('user:1');
```

### Lists

```php
$client->lpush('queue', 'item1');
$client->lpush('queue', 'item2');
$item = $client->rpop('queue');  // "item1"
```

### Sets

```php
$client->sadd('tags', 'php', 'valkey', 'glide');
$members = $client->smembers('tags');
$isMember = $client->sismember('tags', 'php');  // true
```

---

## Architecture Notes

- **Communication layer**: Native C extension calling the Rust core via `glide-ffi`
- Synchronous blocking API - each command blocks until response
- Single multiplexed connection per node
- The PHP client is maintained in a separate repository from the main GLIDE monorepo
- Pre-built binaries are distributed via PIE, Composer, and PECL
- The extension must be enabled in `php.ini` when installed via PECL

---

## Build Complexity

PHP GLIDE is a C extension (not pure PHP or FFI-based). Building from source requires:
- PHP development headers (`php-dev` / `php-devel`)
- Rust toolchain (rustc + cargo)
- Protobuf compiler >= 3.20.0
- GCC, make, autotools
- OpenSSL development headers

The build process: Rust FFI library compilation, then `phpize && ./configure && make install`. Pre-built binaries via PIE/PECL avoid this, but are not yet available for all platforms.

---

## PHPRedis Compatibility Aliases

GLIDE PHP provides PHPRedis-compatible class name aliases for easier migration:

```php
ValkeyGlide::registerPHPRedisAliases();
$client = new Redis();  // Actually a ValkeyGlide instance
```

This maps `Redis` to `ValkeyGlide`, `RedisCluster` to `ValkeyGlideCluster`, and `RedisException` to `ValkeyGlideException`. Requires PHP 8.3+ for internal class aliasing support.

---

## Batching

Batching/transaction API is available. See `features/batching.md` for detailed batching patterns across all languages.

---

## Ecosystem Integrations

No official framework integrations exist. The PHPRedis compatibility aliases (see above) may enable use with Laravel's Redis cache driver, but this is not tested or documented.

---

## Limitations

- PHP is the only GLIDE language client in a separate repository
- No async API - PHP's execution model is inherently synchronous
- Windows is not supported
- Alpine Linux / MUSL is not supported
- Some advanced features (OpenTelemetry, compression) may lag behind the core clients
