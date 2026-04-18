# Connection and Configuration (PHP)

Use when constructing a GLIDE PHP client, switching between standalone and cluster mode, or mapping PHPRedis config to GLIDE config. Assumes PHPRedis knowledge - only divergence is documented.

## Divergence from PHPRedis - construction asymmetry

| | Standalone (`ValkeyGlide`) | Cluster (`ValkeyGlideCluster`) |
|---|---|---|
| Constructor args | **none** | **up to 19** (PHPRedis-style 7 + GLIDE-style 12) |
| How to configure | call `->connect(...)` after `new` | pass all config to `new ValkeyGlideCluster(...)` |
| Can pass `addresses:` to `new`? | **No** (constructor takes zero args) | Yes |

```php
// Standalone - TWO STEPS
$client = new ValkeyGlide();
$client->connect(addresses: [['host' => 'localhost', 'port' => 6379]]);

// Cluster - ONE STEP
$cluster = new ValkeyGlideCluster(
    addresses: [
        ['host' => 'node1.example.com', 'port' => 6379],
        ['host' => 'node2.example.com', 'port' => 6380],
    ],
    use_tls: true,
);
```

Only seed addresses are needed for cluster - topology is discovered automatically.

## PHPRedis-style connect (standalone)

The standalone `->connect()` method accepts BOTH PHPRedis-style positional args AND GLIDE-style named args, but you cannot mix them:

```php
// PHPRedis-style positional
$client->connect('localhost', 6379);
$client->connect('localhost', 6379, 2.5);  // + timeout in seconds

// GLIDE-style named (preferred for new code)
$client->connect(addresses: [['host' => 'localhost', 'port' => 6379]]);
```

PHPRedis-style args (`persistent_id`, `retry_interval`, `read_timeout`) exist in the signature but are marked "not implemented" - pass them only for signature compatibility.

## Full GLIDE-style standalone config

```php
$client = new ValkeyGlide();
$client->connect(
    addresses: [['host' => 'localhost', 'port' => 6379]],
    use_tls: false,
    credentials: ['username' => 'myuser', 'password' => 'mypass'],
    read_from: ValkeyGlide::READ_FROM_PRIMARY,
    request_timeout: 5000,            // milliseconds
    reconnect_strategy: [
        'num_of_retries' => 5,
        'factor' => 2,
        'exponent_base' => 2,
        'jitter_percent' => 15,
    ],
    database_id: 0,
    client_name: 'my-app',
    client_az: null,                   // set to AZ string for AZ_AFFINITY
    advanced_config: [
        'connection_timeout' => 5000,
        'tls_config' => ['use_insecure_tls' => false],
    ],
    lazy_connect: false,
);
```

## Cluster config

Cluster accepts the same GLIDE-style args plus `periodic_checks` (periodic topology refresh) and `refresh_topology_from_initial_nodes` (advanced_config key):

```php
$cluster = new ValkeyGlideCluster(
    addresses: [['host' => 'node1', 'port' => 7001]],
    use_tls: true,
    credentials: ['password' => 'secret'],
    read_from: ValkeyGlide::READ_FROM_AZ_AFFINITY,
    client_az: 'us-east-1a',
    periodic_checks: ValkeyGlideCluster::PERIODIC_CHECK_ENABLED_DEFAULT_CONFIGS,
    request_timeout: 5000,
    reconnect_strategy: [
        'num_of_retries' => 3,
        'factor' => 2,
        'exponent_base' => 10,
        'jitter_percent' => 15,
    ],
    advanced_config: [
        'connection_timeout' => 5000,
        'refresh_topology_from_initial_nodes' => false,
    ],
    lazy_connect: false,
);
```

`database_id` on cluster requires Valkey 9.0+ with `cluster-databases > 1`.

## Authentication

Password / ACL:

```php
// Username + password (ACL)
$client->connect(
    addresses: [['host' => 'localhost', 'port' => 6379]],
    credentials: ['username' => 'myuser', 'password' => 'mypass'],
);

// Password only (legacy AUTH without username)
$client->connect(
    addresses: [['host' => 'localhost', 'port' => 6379]],
    credentials: ['password' => 'mypass'],
);
```

IAM (AWS) - requires `use_tls: true` and `username` to be set:

```php
$client->connect(
    addresses: [['host' => 'my-cluster.cache.amazonaws.com', 'port' => 6379]],
    use_tls: true,
    credentials: [
        'username' => 'iam-user',
        'iamConfig' => [
            ValkeyGlide::IAM_CONFIG_CLUSTER_NAME => 'my-cluster',
            ValkeyGlide::IAM_CONFIG_REGION => 'us-east-1',
            ValkeyGlide::IAM_CONFIG_SERVICE => ValkeyGlide::IAM_SERVICE_ELASTICACHE,
            ValkeyGlide::IAM_CONFIG_REFRESH_INTERVAL => 300,
        ],
    ],
);
```

Tokens refresh automatically in the Rust core.

## Read strategy

Constants on the `ValkeyGlide` class:

| Constant | Value | Behavior |
|----------|-------|----------|
| `READ_FROM_PRIMARY` | 0 | All reads to primary (default) |
| `READ_FROM_PREFER_REPLICA` | 1 | Round-robin replicas, fall back to primary |
| `READ_FROM_AZ_AFFINITY` | 2 | Same-AZ replicas first, requires `client_az` and Valkey 8.0+ |
| `READ_FROM_AZ_AFFINITY_REPLICAS_AND_PRIMARY` | 3 | Same-AZ replicas + primary, then cross-AZ |

## Reconnect strategy

Delay formula: `rand(0 ... factor * (exponent_base ^ attempt))` milliseconds. After `num_of_retries` attempts the delay plateaus at the ceiling - reconnection is infinite.

Keys use snake_case: `num_of_retries`, `factor`, `exponent_base`, `jitter_percent`. Not `numOfRetries` (that's Java).

## PHPRedis compatibility aliases

```php
ValkeyGlide::registerPHPRedisAliases();  // returns bool

// Now these resolve to GLIDE classes
$client = new Redis();              // -> ValkeyGlide
$cluster = new RedisCluster();      // -> ValkeyGlideCluster

try {
    $client->connect('localhost', 6379);
} catch (RedisException $e) {       // -> ValkeyGlideException
    error_log($e->getMessage());
}
```

Call once at application bootstrap. Subsequent calls return `false` (aliases already registered).

## Password rotation without reconnect

```php
$client->updateConnectionPassword('new-secret', immediateAuth: true);
$client->clearConnectionPassword(immediateAuth: false);
```

`immediateAuth: true` re-authenticates now. `immediateAuth: false` defers re-auth until the next command. Works on both standalone and cluster.
