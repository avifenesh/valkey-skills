# Connection and Configuration (PHP)

Use when creating a GLIDE client in PHP, choosing between standalone and cluster mode, configuring authentication, TLS, timeouts, reconnection backoff, read strategy, or the PHPRedis-compatible aliases.

## Contents

- Client Classes (line 15)
- Standalone Connection (line 24)
- Cluster Connection (line 73)
- Authentication (line 93)
- ReadFrom Strategy (line 114)
- Reconnect Strategy (line 124)
- PHPRedis Compatibility Aliases (line 139)

## Client Classes

| Class | Mode | Description |
|-------|------|-------------|
| `ValkeyGlide` | Standalone | Single-node or primary+replicas |
| `ValkeyGlideCluster` | Cluster | Valkey Cluster with auto-topology discovery |

The PHP client provides a synchronous (blocking) API - all commands block until a response is received.

## Standalone Connection

```php
<?php
$client = new ValkeyGlide();
$client->connect(
    addresses: [['host' => 'localhost', 'port' => 6379]]
);

$client->set('key', 'value');
$value = $client->get('key');

$client->close();
```

### PHPRedis-Style Connection

```php
$client = new ValkeyGlide();
$client->connect('localhost', 6379);        // host, port
$client->connect('localhost', 6379, 2.5);   // with timeout
```

### Full Standalone Configuration

```php
$client = new ValkeyGlide();
$client->connect(
    addresses: [['host' => 'localhost', 'port' => 6379]],
    use_tls: false,
    credentials: ['username' => 'myuser', 'password' => 'mypass'],
    read_from: 0,               // 0=PRIMARY
    request_timeout: 5000,      // milliseconds
    reconnect_strategy: [
        'num_of_retries' => 5,
        'factor' => 2.0,
        'exponent_base' => 2,
    ],
    database_id: 0,
    client_name: 'my-app',
    client_az: null,            // for AZ_AFFINITY reads
    advanced_config: [
        'connection_timeout' => 5000,
        'socket_timeout' => 3000,
    ],
    lazy_connect: false,
);
```

## Cluster Connection

```php
$client = new ValkeyGlideCluster(
    addresses: [
        ['host' => 'node1.example.com', 'port' => 6379],
        ['host' => 'node2.example.com', 'port' => 6380],
    ]
);

$client->set('key', 'value');
$client->close();
```

Only seed addresses are needed - GLIDE discovers full topology automatically.

PHPRedis-style: `new ValkeyGlideCluster(seeds: [['host' => 'localhost', 'port' => 7001]])`.

Cluster-specific options: `periodic_checks` (topology refresh interval in seconds), `client_az` (for AZ affinity). All other options (`use_tls`, `credentials`, `read_from`, `request_timeout`, `reconnect_strategy`, `advanced_config`, `lazy_connect`) match standalone.

## Authentication

```php
// Username + password (ACL)
$client->connect(
    addresses: [['host' => 'localhost', 'port' => 6379]],
    credentials: ['username' => 'myuser', 'password' => 'mypass'],
);

// Password only
$client->connect(
    addresses: [['host' => 'localhost', 'port' => 6379]],
    credentials: ['password' => 'mypass'],
);

// IAM authentication (AWS) - requires use_tls: true
// credentials['iamConfig'] with keys: IAM_CONFIG_CLUSTER_NAME, IAM_CONFIG_REGION,
// IAM_CONFIG_SERVICE (IAM_SERVICE_ELASTICACHE or IAM_SERVICE_MEMORYDB),
// IAM_CONFIG_REFRESH_INTERVAL (default 300s). Tokens refresh automatically.
```

## ReadFrom Strategy

| Value | Strategy | Behavior |
|-------|----------|----------|
| `0` | PRIMARY | All reads to primary (default) |
| `1` | PREFER_REPLICA | Round-robin replicas, fallback to primary |
| `2` | AZ_AFFINITY | Same-AZ replicas, fallback to others |

AZ affinity requires Valkey 8.0+ and `client_az` to be set.

## Reconnect Strategy

Delay follows `rand(0 ... factor * (exponent_base ^ N))`:

```php
$client->connect(
    addresses: $addresses,
    reconnect_strategy: [
        'num_of_retries' => 5,    // retries before delay plateaus
        'factor' => 2.0,          // base delay multiplier
        'exponent_base' => 2,     // exponential growth factor
    ],
);
```

## PHPRedis Compatibility Aliases

Register class aliases to use PHPRedis class names:

```php
ValkeyGlide::registerPHPRedisAliases();

// Now these work:
$client = new Redis();          // -> ValkeyGlide
$cluster = new RedisCluster();  // -> ValkeyGlideCluster

try {
    $client->connect('localhost', 6379);
} catch (RedisException $e) {   // -> ValkeyGlideException
    echo $e->getMessage();
}
```

Requires PHP 8.3+ for internal class aliasing support.
