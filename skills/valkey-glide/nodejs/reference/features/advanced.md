# Advanced Features

Use when configuring TLS, authentication, Lua scripting, protocol version, response decoding, or handling error types in the GLIDE Node.js client.

## TLS Configuration

Enable TLS with `useTLS`. The server must also be configured for TLS.

```typescript
const client = await GlideClient.createClient({
    addresses: [{ host: "valkey.example.com", port: 6380 }],
    useTLS: true,
});
```

Custom CA certificates and insecure mode are set via `advancedConfiguration`:

```typescript
import { readFileSync } from "fs";

const client = await GlideClient.createClient({
    addresses: [{ host: "valkey.example.com", port: 6380 }],
    useTLS: true,
    advancedConfiguration: {
        connectionTimeout: 5000, // ms, default 2000
        tlsAdvancedConfiguration: {
            rootCertificates: readFileSync("/path/to/ca.pem"), // string or Buffer, PEM format
            // insecure: true, // skip cert verification - dev only, throws ConfigurationError without useTLS
        },
    },
});
```

## Authentication

### Password-Based

Pass `credentials` with `password` and optional `username`. If `username` is omitted, Valkey uses `"default"`.

```typescript
const client = await GlideClient.createClient({
    addresses: [{ host: "localhost", port: 6379 }],
    credentials: { username: "myuser", password: "mypass" },
});
```

### IAM Authentication (AWS)

For ElastiCache or MemoryDB. Requires `username`, `iamConfig`, and TLS. Password and IAM are mutually exclusive.

```typescript
import { GlideClient, ServiceType } from "@valkey/valkey-glide";

const client = await GlideClient.createClient({
    addresses: [{ host: "my-cluster.amazonaws.com", port: 6379 }],
    useTLS: true,
    credentials: {
        username: "myIamUser",
        iamConfig: {
            clusterName: "my-cluster",
            service: ServiceType.Elasticache, // or ServiceType.MemoryDB
            region: "us-east-1",
            refreshIntervalSeconds: 300, // optional, default 300
        },
    },
});
```

### Runtime Password Update

Update the stored password without recreating the client. Not supported with IAM.

```typescript
await client.updateConnectionPassword("newpass", true); // true = re-auth immediately
```

### Manual IAM Token Refresh

Force an immediate IAM token refresh outside the automatic interval. Only available when IAM authentication is configured.

```typescript
await client.refreshIamToken(); // => "OK"
```

**Signature:** `refreshIamToken() => Promise<GlideString>` - throws `ConfigurationError` if IAM is not enabled.

## Lua Scripting

The `Script` class manages Lua script caching via `EVALSHA` with automatic `EVAL` fallback. Script objects are NOT garbage collected - call `release()` when done.

```typescript
import { Script } from "@valkey/valkey-glide";

const script = new Script("return { KEYS[1], ARGV[1] }");
const result = await client.invokeScript(script, {
    keys: ["mykey"],
    args: ["myvalue"],
});
console.log(result); // ["mykey", "myvalue"]
script.release();
```

Server-side logic example:

```typescript
const script = new Script(`
    redis.call('SET', KEYS[1], ARGV[1])
    return redis.call('GET', KEYS[1])
`);
const result = await client.invokeScript(script, {
    keys: ["counter"],
    args: ["42"],
});
script.release();
```

In cluster mode, all keys must map to the same hash slot. For keyless scripts use `invokeScriptWithRoute` on `GlideClusterClient`:

```typescript
const result = await clusterClient.invokeScriptWithRoute(script, { args: ["bar"] });
```

| Method | Description |
|--------|-------------|
| `new Script(code)` | Create script, compute SHA1, store in memory |
| `script.getHash()` | Return the SHA1 hash string |
| `script.release()` | Decrement ref count; free memory when zero |

Retrieve a cached script's source (Valkey 8.0+):

```typescript
const source = await client.scriptShow(script.getHash());
// Returns the original Lua source code
```

**Signature:** `scriptShow(sha1, options?) => Promise<GlideString>` - throws if SHA1 not in cache.

Scripts are NOT supported in batch operations. Use `customCommand(["EVAL", ...])` in batches instead.

## Error Types

All errors extend `ValkeyError`. Import from `@valkey/valkey-glide`.

| Error | Parent | When |
|-------|--------|------|
| `RequestError` | `ValkeyError` | Server-side or protocol error |
| `TimeoutError` | `RequestError` | Request exceeded `requestTimeout` (default 250ms) |
| `ConnectionError` | `RequestError` | Connection lost; auto-reconnect in progress |
| `ExecAbortError` | `RequestError` | Atomic batch aborted (WATCH conflict) |
| `ConfigurationError` | `RequestError` | Invalid config (TLS mismatch, missing params) |
| `ClosingError` | `ValkeyError` | Client closed; must create a new client |

```typescript
import {
    ClosingError, ConnectionError, RequestError, TimeoutError,
} from "@valkey/valkey-glide";

try {
    const value = await client.get("key");
} catch (error) {
    if (error instanceof TimeoutError) {
        // Increase requestTimeout or check server load
    } else if (error instanceof ConnectionError) {
        // Transient - GLIDE is auto-reconnecting
    } else if (error instanceof ClosingError) {
        // Terminal - create a new client
    } else if (error instanceof RequestError) {
        // General failure
    }
}
```

Check specific subclasses before `RequestError` - `TimeoutError`, `ConnectionError`, `ExecAbortError`, and `ConfigurationError` all extend it.

## Decoder Options

GLIDE decodes responses as strings by default. Use `Decoder.Bytes` for raw `Buffer` responses.

```typescript
import { Decoder } from "@valkey/valkey-glide";

// Client-wide default
const client = await GlideClient.createClient({
    addresses: [{ host: "localhost", port: 6379 }],
    defaultDecoder: Decoder.String, // default if not set
});

// Per-command override
const buf = await client.get("key", { decoder: Decoder.Bytes });
```

| Decoder | Return Type | Use Case |
|---------|-------------|----------|
| `Decoder.String` | `string` | Text, JSON, counters |
| `Decoder.Bytes` | `Buffer` | Binary data, images, serialized objects |

If decoding fails, data may be unrecoverably lost. Use `Decoder.Bytes` for non-UTF-8 binary data.

## Protocol Version

GLIDE defaults to RESP3. PubSub subscriptions at client creation require RESP3.

```typescript
import { ProtocolVersion } from "@valkey/valkey-glide";

const client = await GlideClient.createClient({
    addresses: [{ host: "localhost", port: 6379 }],
    protocol: ProtocolVersion.RESP3, // default
});
```

| Version | Constant | Notes |
|---------|----------|-------|
| RESP2 | `ProtocolVersion.RESP2` | Legacy. PubSub subscriptions throw `ConfigurationError`. |
| RESP3 | `ProtocolVersion.RESP3` | Default. Required for PubSub at client creation. |

## Valkey Functions (7.0+)

Server-side functions loaded from libraries. Unlike Lua scripts, functions persist across restarts and support named invocation. These methods are on `GlideClient` (standalone) and `GlideClusterClient` (cluster).

```typescript
import { GlideClient, FlushMode, FunctionRestorePolicy } from "@valkey/valkey-glide";

// Load a library with a function
const code = "#!lua name=mylib \n redis.register_function('myfunc', function(keys, args) return args[1] end)";
const libName = await client.functionLoad(code, { replace: true });
// "mylib"

// Call the function
const result = await client.fcall("myfunc", ["key1"], ["hello"]);
// "hello"

// Read-only variant - safe for replicas
const roResult = await client.fcallReadonly("myfunc", ["key1"], ["hello"]);

// List libraries and their functions
const libs = await client.functionList({ libNamePattern: "mylib*", withCode: true });
// [{ library_name: "mylib", engine: "LUA", functions: [{ name: "myfunc", ... }], library_code: "..." }]

// Stats - running function info and engine stats
const stats = await client.functionStats();
// { "127.0.0.1:6379": { running_script: null, engines: { LUA: { libraries_count: 1, functions_count: 1 } } } }

// Delete a library
await client.functionDelete("mylib"); // "OK"

// Flush all libraries
await client.functionFlush(FlushMode.SYNC); // "OK"

// Kill a running read-only function
await client.functionKill(); // "OK"

// Dump/Restore for migration
const payload = await client.functionDump();      // Buffer
await client.functionRestore(payload, FunctionRestorePolicy.REPLACE); // "OK"
```

| Method | Signature | Description |
|--------|-----------|-------------|
| `functionLoad` | `(code, options?) => Promise<GlideString>` | Load library; `options.replace` overwrites |
| `functionDelete` | `(libraryName) => Promise<"OK">` | Delete a library and its functions |
| `functionList` | `(options?) => Promise<FunctionListResponse>` | List libraries; filter with `libNamePattern` |
| `functionStats` | `(options?) => Promise<FunctionStatsFullResponse>` | Running function and engine info |
| `functionFlush` | `(mode?) => Promise<"OK">` | Delete all libraries |
| `functionKill` | `() => Promise<"OK">` | Kill running read-only function |
| `functionDump` | `() => Promise<Buffer>` | Serialize all libraries |
| `functionRestore` | `(payload, policy?) => Promise<"OK">` | Restore from dump; policy: APPEND, FLUSH, REPLACE |
| `fcall` | `(func, keys, args, options?) => Promise<GlideReturnType>` | Invoke a loaded function |
| `fcallReadonly` | `(func, keys, args, options?) => Promise<GlideReturnType>` | Invoke read-only function (replica-safe) |

## Client Statistics

Returns internal GLIDE core statistics. Synchronous - not a server command.

```typescript
const stats = client.getStatistics();
console.log(stats); // { total_connections: 1, ... }
```

**Signature:** `getStatistics() => object`
