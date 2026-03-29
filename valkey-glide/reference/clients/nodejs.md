# Node.js Client

Use when building Node.js applications with Valkey GLIDE - Promise-based async API with TypeScript support.

## Installation

```bash
npm install @valkey/valkey-glide
```

**Requirements:** Node.js 16+

**Platform support:** Linux glibc (x86_64, arm64), Linux musl/Alpine (x86_64, arm64), macOS (Apple Silicon, x86_64). No Windows support.

For npm users on Linux, npm >= 11 is recommended because it supports optional download based on libc (glibc vs musl). Yarn users are not affected.

Supports both ESM and CommonJS module systems. TypeScript definitions are included.

---

## Client Classes

| Class | Mode | Description |
|-------|------|-------------|
| `GlideClient` | Standalone | Single-node or primary+replicas |
| `GlideClusterClient` | Cluster | Valkey Cluster with auto-topology |

Both extend `BaseClient` and are created via the static `createClient()` method.

---

## Standalone Connection

```typescript
import { GlideClient } from "@valkey/valkey-glide";

const client = await GlideClient.createClient({
    addresses: [{ host: "localhost", port: 6379 }],
    requestTimeout: 5000,
});

try {
    await client.set("greeting", "Hello from GLIDE");
    const value = await client.get("greeting");
    console.log(`Got: ${value}`);
} finally {
    client.close();
}
```

### CommonJS

```javascript
const { GlideClient } = require("@valkey/valkey-glide");

async function main() {
    const client = await GlideClient.createClient({
        addresses: [{ host: "localhost", port: 6379 }],
    });

    await client.set("key", "value");
    const value = await client.get("key");
    console.log(value);

    client.close();
}
main();
```

---

## Cluster Connection

```typescript
import { GlideClusterClient } from "@valkey/valkey-glide";

const client = await GlideClusterClient.createClient({
    addresses: [
        { host: "node1.example.com", port: 6379 },
        { host: "node2.example.com", port: 6380 },
    ],
    readFrom: "preferReplica",
});

await client.set("key", "value");
const value = await client.get("key");

client.close();
```

Only seed addresses are needed - GLIDE discovers the full cluster topology automatically.

---

## Configuration

Configuration is passed as a plain object to `createClient()`. The types are defined as TypeScript interfaces.

### GlideClientConfiguration

Extends `BaseClientConfiguration` with standalone-specific options.

```typescript
import {
    GlideClient,
    GlideClientConfiguration,
    ProtocolVersion,
} from "@valkey/valkey-glide";

const config: GlideClientConfiguration = {
    addresses: [{ host: "localhost", port: 6379 }],
    useTLS: true,
    credentials: {
        username: "myuser",
        password: "mypass",
    },
    readFrom: "preferReplica",
    requestTimeout: 5000,
    connectionBackoff: {
        numberOfRetries: 5,
        factor: 1000,
        exponentBase: 2,
        jitterPercent: 20,
    },
    databaseId: 0,
    clientName: "my-app",
    protocol: ProtocolVersion.RESP3,
    inflightRequestsLimit: 1000,
    readOnly: false,
};

const client = await GlideClient.createClient(config);
```

### GlideClusterClientConfiguration

Extends `BaseClientConfiguration` with cluster-specific options. Adds `periodicChecks` and sharded PubSub support.

```typescript
import { GlideClusterClient } from "@valkey/valkey-glide";

const client = await GlideClusterClient.createClient({
    addresses: [{ host: "node1.example.com", port: 6379 }],
    readFrom: "AZAffinity",
    clientAz: "us-east-1a",
    periodicChecks: { duration_in_sec: 30 },
});
```

---

## Configuration Details

### Address Format

Addresses are plain objects with `host` and `port`:

```typescript
{ host: "localhost", port: 6379 }
```

### Credentials

See `features/tls-auth.md` for TLS and authentication details including IAM.

```typescript
credentials: {
    username: "myuser",    // optional, defaults to "default"
    password: "mypass",
}
```

### Connection Backoff

```typescript
connectionBackoff: {
    numberOfRetries: 5,     // escalation attempts
    factor: 1000,           // base delay in ms
    exponentBase: 2,        // exponential growth
    jitterPercent: 20,             // jitter percentage
}
```

### ReadFrom

String values passed to the `readFrom` option:

| Value | Behavior |
|-------|----------|
| `"primary"` | All reads to primary (default) |
| `"preferReplica"` | Round-robin replicas, fallback to primary |
| `"AZAffinity"` | Prefer same-AZ replicas (requires `clientAz`) |
| `"AZAffinityReplicasAndPrimary"` | Same-AZ replicas, then primary, then remote |

AZ Affinity strategies require Valkey 8.0+ and `clientAz` must be set. See `features/az-affinity.md` for detailed AZ routing behavior.

---

## Error Handling

Error classes are exported from the main package:

| Error | Description |
|-------|-------------|
| `RequestError` | Base for request-level failures |
| `TimeoutError` | Request exceeded `requestTimeout` |
| `ConnectionError` | Connection lost (auto-reconnects) |
| `ClosingError` | Client closed, no longer usable |
| `ExecAbortError` | Transaction aborted (WATCH key changed) |
| `ConfigurationError` | Invalid client configuration |

```typescript
import {
    RequestError,
    TimeoutError,
    ConnectionError,
} from "@valkey/valkey-glide";

try {
    const value = await client.get("key");
} catch (error) {
    if (error instanceof TimeoutError) {
        console.error("Request timed out");
    } else if (error instanceof ConnectionError) {
        console.error("Connection lost - reconnecting");
    } else if (error instanceof RequestError) {
        console.error(`Request failed: ${error.message}`);
    }
}
```

---

## Batching

See `features/batching.md` for detailed batching API patterns across all languages.

### Atomic Batch (Transaction)

```typescript
import { Batch } from "@valkey/valkey-glide";

const tx = new Batch()
    .set("key", "value")
    .incr("counter")
    .get("key");
const result = await client.exec(tx);
// ["OK", 1, "value"]
```

### Non-Atomic Batch (Pipeline)

```typescript
import { Batch } from "@valkey/valkey-glide";

const batch = new Batch()
    .set("k1", "v1")
    .set("k2", "v2")
    .get("k1");
const result = await client.exec(batch);
```

For cluster mode, use `ClusterBatch`.

---

## Exports

The main entry point (`@valkey/valkey-glide`) re-exports everything from:

- `GlideClient` and `GlideClusterClient` - client classes
- `BaseClient` - shared base with all data commands
- `Batch`, `ClusterBatch` - batching/pipeline support
- `Commands` - command option types and factories
- `Errors` - error classes
- `Logger` - GLIDE logging configuration
- `OpenTelemetry` - tracing and metrics configuration (see `features/opentelemetry.md`)
- Server modules: `GlideFt` (search), `GlideJson` (JSON)

---

## Type System

GLIDE uses several core types:

| Type | Description |
|------|-------------|
| `GlideString` | `string \| Buffer` - binary-safe string type |
| `GlideReturnType` | Union of all possible return types |
| `GlideRecord<T>` | Record type for key-value pairs |
| `Decoder` | Enum for response decoding (`String`, `Bytes`) |
| `DecoderOption` | Option to control response decoding per command |

---

## Architecture Notes

- **Communication layer**: napi-rs (NAPI v2) - native Rust bindings for Node.js
- The native binding is auto-generated and exported from `build-ts/native`
- Protobuf serialization for command requests and responses
- Single multiplexed connection per node
- All command methods return `Promise<T>`
- TypeScript types are bundled - no separate `@types` package needed

---

## Ecosystem Integrations

- `@fastify/valkey-glide` - official Fastify plugin for caching and session management
- `rate-limiter-flexible` - rate limiting with GLIDE backend
- `redlock-universal` - distributed locks with native GLIDE adapter
- `aws-lambda-powertools-typescript` - idempotency feature integration
