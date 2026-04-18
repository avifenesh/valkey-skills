# Connection and configuration (Node.js)

Use when creating clients, configuring auth, TLS, timeouts, reconnection, read strategy, or closing connections. Covers what differs from `ioredis` / `node-redis` - basic `new Redis({ host, port })` patterns are assumed knowable from training.

## Divergence from ioredis / node-redis

| ioredis / node-redis | GLIDE Node |
|---------------------|-----------|
| `new Redis({ host, port })` constructs immediately | `await GlideClient.createClient(config)` - async static factory |
| `new Redis.Cluster([{host, port}])` | `await GlideClusterClient.createClient({ addresses })` - distinct type, not a pool wrapper |
| Connection pool with `maxRetriesPerRequest` | Single multiplexed connection per node - no pool knob |
| `client.on('error', ...)` event emitter | Errors surface per-Promise via `await`; no emitter |
| `client.disconnect()` / `client.quit()` | `client.close()` - synchronous, returns `void`, not Promise |
| `retryStrategy: (times) => ...` function | `connectionBackoff` object with `numberOfRetries`, `factor`, `exponentBase`, `jitterPercent` |
| `lazyConnect: true` on ioredis defers implicit connect | `lazyConnect: true` on GLIDE defers the first TCP connect to the first command |

## GlideClient vs GlideClusterClient

| Client | Mode | Use When |
|--------|------|----------|
| `GlideClient` | Standalone | Connecting to a single Valkey server or a replicated setup without cluster mode |
| `GlideClusterClient` | Cluster | Connecting to a Valkey cluster with hash-slot-based sharding |

Both are created via a static `createClient()` method that returns a promise. Both extend `BaseClient` and share the same base configuration interface.

```typescript
import { GlideClient, GlideClusterClient } from "@valkey/valkey-glide";
```

## Creating a Standalone Client

```typescript
const client = await GlideClient.createClient({
    addresses: [{ host: "localhost", port: 6379 }],
});
```

With full configuration:

```typescript
const client = await GlideClient.createClient({
    addresses: [
        { host: "primary.example.com", port: 6379 },
        { host: "replica1.example.com", port: 6379 },
    ],
    databaseId: 1,
    credentials: { username: "user1", password: "passwordA" },
    useTLS: true,
    requestTimeout: 5000,
    protocol: ProtocolVersion.RESP3,
    clientName: "my-app",
    readFrom: "preferReplica",
    defaultDecoder: Decoder.String,
    inflightRequestsLimit: 1000,
    connectionBackoff: {
        numberOfRetries: 5,
        factor: 1000,
        exponentBase: 2,
        jitterPercent: 20,
    },
    lazyConnect: true,
    advancedConfiguration: {
        connectionTimeout: 5000,
        tcpNoDelay: true,
        tlsAdvancedConfiguration: { insecure: false },
    },
});
```

## Creating a Cluster Client

```typescript
const client = await GlideClusterClient.createClient({
    addresses: [
        { host: "cluster-node-1.example.com", port: 6379 },
        { host: "cluster-node-2.example.com", port: 6379 },
    ],
    periodicChecks: { duration_in_sec: 30 },
});
```

The client auto-discovers the full cluster topology from the seed addresses.

## BaseClientConfiguration - Shared Options

Both client types inherit these options from `BaseClientConfiguration`.

| Property | Type | Default | Description |
|----------|------|---------|-------------|
| `addresses` | `{ host: string; port?: number }[]` | required | Server addresses. Port defaults to 6379 |
| `databaseId` | `number` | `0` | Logical database index. Cluster mode requires Valkey 9.0+ |
| `useTLS` | `boolean` | `false` | Enable TLS encryption |
| `credentials` | `ServerCredentials` | none | Authentication credentials (see below) |
| `requestTimeout` | `number` | `250` | Request timeout in ms (includes retries and reconnection) |
| `readFrom` | `ReadFrom` | `"primary"` | Read routing strategy |
| `protocol` | `ProtocolVersion` | `RESP3` | Wire protocol version |
| `clientName` | `string` | none | Name set via CLIENT SETNAME on connect |
| `defaultDecoder` | `Decoder` | `Decoder.String` | Default response decoder (`String` or `Bytes`) |
| `inflightRequestsLimit` | `number` | `1000` | Max concurrent in-flight requests |
| `clientAz` | `string` | none | Client availability zone for AZ-affinity reads |
| `connectionBackoff` | `object` | built-in default | Reconnection strategy (see below) |
| `lazyConnect` | `boolean` | `false` | Defer connection until first command |

## ServerCredentials

Password-based (username optional, defaults to "default"):

```typescript
credentials: { username: "myuser", password: "secret" }
```

IAM authentication (AWS ElastiCache/MemoryDB):

```typescript
credentials: {
    username: "iam-user",
    iamConfig: {
        clusterName: "my-cluster",
        service: ServiceType.Elasticache, // or ServiceType.MemoryDB
        region: "us-east-1",
        refreshIntervalSeconds: 300, // default: 300s
    },
}
```

Password and `iamConfig` are mutually exclusive.

## ReadFrom Strategy

| Value | Behavior |
|-------|----------|
| `"primary"` | Always read from primary (freshest data) |
| `"preferReplica"` | Round-robin across replicas; fallback to primary |
| `"AZAffinity"` | Round-robin across replicas in the client's AZ; fallback to primary |
| `"AZAffinityReplicasAndPrimary"` | Round-robin across all nodes in the client's AZ (replicas first, then primary); fallback to any node |

Set `clientAz` when using AZ-affinity strategies:

```typescript
const client = await GlideClusterClient.createClient({
    addresses: [{ host: "node1.example.com", port: 6379 }],
    readFrom: "AZAffinity",
    clientAz: "us-east-1a",
});
```

## Connection Backoff

Controls reconnection behavior on disconnection. Delay follows `rand(0 ... factor * (exponentBase ^ N))` where N is the attempt number, with optional jitter.

| Property | Type | Description |
|----------|------|-------------|
| `numberOfRetries` | `number` | Retries before delay becomes constant |
| `factor` | `number` | Base delay multiplier in ms |
| `exponentBase` | `number` | Exponential growth factor |
| `jitterPercent` | `number` (optional) | Random jitter percentage on calculated delay |

The client retries indefinitely. Once `numberOfRetries` is reached, the delay stays constant at the maximum value.

## AdvancedBaseClientConfiguration

Both clients accept an `advancedConfiguration` property with:

| Property | Type | Default | Description |
|----------|------|---------|-------------|
| `connectionTimeout` | `number` | `2000` | TCP/TLS connection timeout in ms |
| `tcpNoDelay` | `boolean` | `true` | Disable Nagle's algorithm for lower latency |
| `tlsAdvancedConfiguration.insecure` | `boolean` | `false` | Skip TLS certificate verification (dev only) |
| `tlsAdvancedConfiguration.rootCertificates` | `string \| Buffer` | system CA | Custom root CA in PEM format |

## GlideClusterClient-Specific Options

| Property | Type | Default | Description |
|----------|------|---------|-------------|
| `periodicChecks` | `PeriodicChecks` | `"enabledDefaultConfigs"` | Cluster topology refresh interval |
| `advancedConfiguration.refreshTopologyFromInitialNodes` | `boolean` | `false` | Use only seed nodes for topology refresh |

`PeriodicChecks` is one of:
- `"enabledDefaultConfigs"` - periodic checks with default interval
- `"disabled"` - no periodic checks
- `{ duration_in_sec: number }` - custom interval in seconds

## Lazy Connect

When `lazyConnect: true`, no connection is made during `createClient()`. The first command triggers connection. The first command's total latency includes `connectionTimeout` (TCP/TLS handshake) plus `requestTimeout`.

```typescript
const client = await GlideClient.createClient({
    addresses: [{ host: "localhost", port: 6379 }],
    lazyConnect: true,
});
// No connection yet
await client.ping(); // connects now, then sends PING
```

## Protocol Version

RESP3 (default) supports richer types (maps, sets, booleans) natively. RESP2 is available for compatibility with older proxies or middleware. Set via `protocol: ProtocolVersion.RESP2`.

## Closing Connections

Call `close()` to terminate the client and release all resources. All pending promises are rejected with `ClosingError`. The method is synchronous - the client cannot be reused after closing.

```typescript
client.close();
client.close("Shutting down gracefully"); // custom error message for pending promises
```
