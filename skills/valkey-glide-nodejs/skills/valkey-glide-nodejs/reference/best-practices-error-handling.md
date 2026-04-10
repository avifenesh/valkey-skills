# Error Handling

Use when implementing error handling, retry logic, or batch error semantics in the GLIDE Node.js client.

## Contents

- Error Types (line 15)
- Basic Error Handling (line 35)
- Batch Error Handling (line 59)
- Reconnection Behavior (line 106)
- Failover and Timeout (line 129)

---

## Error Types

GLIDE exports typed error classes from `@valkey/valkey-glide`:

```typescript
import {
    RequestError,
    TimeoutError,
    ConnectionError,
    ClosingError,
} from "@valkey/valkey-glide";
```

| Error | When It Occurs | Recovery |
|-------|---------------|----------|
| `RequestError` | Base class for server/protocol errors | Check message for details |
| `TimeoutError` | Request exceeded `requestTimeout` (default 250ms) | Increase timeout or check server load |
| `ConnectionError` | Connection lost | GLIDE auto-reconnects; retry the operation |
| `ClosingError` | Client was closed while requests were pending | Create a new client |

## Basic Error Handling

```typescript
import { GlideClient, TimeoutError, ConnectionError, RequestError } from "@valkey/valkey-glide";

try {
    const value = await client.get("key");
} catch (error) {
    if (error instanceof TimeoutError) {
        // Request exceeded requestTimeout - check server load or increase timeout
    } else if (error instanceof ConnectionError) {
        // Connection lost - GLIDE is already reconnecting
        // Retry the operation after a brief delay
    } else if (error instanceof RequestError) {
        // General request failure (WRONGTYPE, auth errors, etc.)
        console.error(`Request failed: ${error.message}`);
    }
}
```

`RequestError` is the base class - catch it last as a catch-all.

---

## Batch Error Handling

The `raiseOnError` parameter on `client.exec()` controls how batch errors surface:

### raiseOnError = true

Throws `RequestError` on the first error. Use when all commands must succeed.

```typescript
import { Batch, RequestError } from "@valkey/valkey-glide";

const batch = new Batch(true).set("key", "val").get("key");
try {
    const results = await client.exec(batch, true);
} catch (error) {
    if (error instanceof RequestError) {
        console.error(`Batch failed: ${error.message}`);
    }
}
```

### raiseOnError = false

Errors appear inline in the results array. Use for partial-success workloads.

```typescript
import { Batch, RequestError } from "@valkey/valkey-glide";

const batch = new Batch(false)
    .set("key", "value")
    .lpush("key", ["oops"])  // WRONGTYPE error
    .get("key");

const results = await client.exec(batch, false);
for (const item of results!) {
    if (item instanceof RequestError) {
        console.log(`Failed: ${item.message}`);
    } else {
        console.log(`OK: ${item}`);
    }
}
```

Atomic batches with WATCH return `null` from `exec()` if a watched key was modified.

---

## Reconnection Behavior

GLIDE reconnects automatically on connection loss with exponential backoff:

```typescript
const client = await GlideClient.createClient({
    addresses: [{ host: "localhost", port: 6379 }],
    connectionBackoff: {
        numberOfRetries: 5,
        factor: 100,
        exponentBase: 2,
        jitterPercent: 20,
    },
});
```

- Delay formula: `rand(0 ... factor * (exponentBase ^ attempt))`
- After `numberOfRetries`, delay stays at the ceiling indefinitely
- PubSub channels are automatically resubscribed on reconnect
- Permanent errors (NOAUTH, WRONGPASS) are not retried

---

## Failover and Timeout

During cluster failover, expect `ConnectionError` bursts for 1-5 seconds. GLIDE refreshes the slot map and re-routes automatically. Retry failed operations.

Frequent `TimeoutError` indicates server load - verify before increasing timeout:

```typescript
const client = await GlideClient.createClient({
    addresses: [{ host: "localhost", port: 6379 }],
    requestTimeout: 1000, // ms, default 250
});
```

GLIDE auto-extends timeouts for blocking commands (BLPOP, XREADGROUP BLOCK) by 500ms beyond the block duration.
