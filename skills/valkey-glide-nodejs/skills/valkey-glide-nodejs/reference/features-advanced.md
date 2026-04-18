# Advanced features (Node.js)

Use when configuring TLS, IAM authentication, Lua scripts, Valkey Functions, the decoder, or handling error types. Covers GLIDE-specific divergence from ioredis; basic setup examples are in [features-connection](features-connection.md).

## TLS and mTLS

Basic TLS is `useTLS: true` at the top of the config. Everything else (custom CA, insecure dev mode) is in `advancedConfiguration.tlsAdvancedConfiguration`:

```typescript
advancedConfiguration: {
    connectionTimeout: 5000,
    tlsAdvancedConfiguration: {
        rootCertificates: readFileSync("/path/to/ca.pem"),  // string | Buffer, PEM
        insecure: false,  // true bypasses cert verification; throws ConfigurationError without useTLS
    },
}
```

## IAM auth (AWS ElastiCache / MemoryDB)

GLIDE-only, no ioredis equivalent. Password and IAM are mutually exclusive on one `credentials` object; IAM requires TLS and a username.

```typescript
import { ServiceType } from "@valkey/valkey-glide";

credentials: {
    username: "iam-user",
    iamConfig: {
        clusterName: "my-cluster",
        service: ServiceType.Elasticache,  // or ServiceType.MemoryDB (PascalCase!)
        region: "us-east-1",
        refreshIntervalSeconds: 300,  // optional; default 300
    },
}
```

Runtime credential updates:

```typescript
await client.updateConnectionPassword("newpass");          // stored; used on next reconnect
await client.updateConnectionPassword("newpass", true);    // re-AUTH immediately
await client.updateConnectionPassword(null);               // clear stored password
await client.refreshIamToken();                            // force IAM refresh; throws ConfigurationError if IAM not configured
```

## Lua Scripting

Replaces ioredis's `defineCommand` pattern. The `Script` class wraps `EVALSHA` with automatic `EVAL` fallback.

**Critical**: `Script` objects are NOT garbage collected - always call `.release()` when done, or you leak native memory.

```typescript
import { Script } from "@valkey/valkey-glide";

const script = new Script("return { KEYS[1], ARGV[1] }");
try {
    const result = await client.invokeScript(script, {
        keys: ["mykey"],
        args: ["myvalue"],
    });
} finally {
    script.release();
}
```

Cluster: keyed scripts require all keys in one hash slot. For keyless scripts with explicit routing:

```typescript
await clusterClient.invokeScriptWithRoute(script, { args: ["bar"], route: "randomNode" });
```

Retrieve cached source (Valkey 8.0+): `await client.scriptShow(script.getHash())`.

**Scripts are NOT usable inside a Batch.** For scripts in a batch, call `batch.customCommand(["EVAL", ...])` instead.

## Error hierarchy

Subclass tree in `@valkey/valkey-glide`:

```
ValkeyError (abstract)           # Node's base is ValkeyError, NOT GlideError (Python uses GlideError)
├── ClosingError                 # client closed; must create a new client
└── RequestError                 # catches everything below too
    ├── TimeoutError             # request exceeded requestTimeout (default 250ms)
    ├── ExecAbortError           # atomic batch aborted (WATCH conflict, MULTI errors)
    ├── ConnectionError          # temporary - auto-reconnect in progress
    └── ConfigurationError       # invalid config (TLS mismatch, RESP2+PubSub, etc.)
```

**Common mistake**: catching `RequestError` also catches `TimeoutError`, `ConnectionError`, `ConfigurationError`, `ExecAbortError` - they are subclasses, not siblings. Check specific subclasses first. Use `ValkeyError` only when you also want `ClosingError`.

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

ioredis has no first-class Functions support - this is entirely new territory for migrating agents. Functions persist across restarts (unlike scripts) and support named invocation.

Methods on `GlideClient` and `GlideClusterClient`:

| Method | Purpose |
|--------|---------|
| `functionLoad(code, { replace? })` | Load a library; returns library name |
| `functionDelete(libName)` | Delete one library |
| `functionList({ libNamePattern?, withCode? })` | List libraries / functions |
| `functionStats({ route? })` | Running function info + engine stats |
| `functionFlush(mode?)` | Delete all libraries; mode `FlushMode.SYNC` / `ASYNC` |
| `functionKill()` | Kill a running read-only function |
| `functionDump()` → `Buffer` | Serialize all libraries |
| `functionRestore(payload, policy?)` | Restore from dump; `FunctionRestorePolicy.APPEND`/`FLUSH`/`REPLACE` |
| `fcall(func, keys, args, options?)` | Invoke a loaded function |
| `fcallReadonly(func, keys, args, options?)` | Read-only variant (replica-safe) |

Cluster-only variants route explicitly: `fcallWithRoute` / `fcallReadonlyWithRoute` on `GlideClusterClient`.

Example library shebang: `"#!lua name=mylib\nredis.register_function('myfunc', function(keys, args) return args[1] end)"`.

## Client statistics

Returns internal GLIDE core telemetry (multiplexer counters, compression ratios, PubSub sync). **Synchronous** - it's a local accessor, not a server call (unlike Python which exposes the same as an async method).

```typescript
const stats = client.getStatistics();  // { total_connections: "1", ... } - all values stringified
```

Keys: `total_connections`, `total_clients`, `total_values_compressed`, `total_values_decompressed`, `total_original_bytes`, `total_bytes_compressed`, `total_bytes_decompressed`, `compression_skipped_count`, `subscription_out_of_sync_count`, `subscription_last_sync_timestamp`.
