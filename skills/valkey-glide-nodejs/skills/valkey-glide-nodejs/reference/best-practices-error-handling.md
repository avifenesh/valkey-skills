# Error Handling (Node.js)

Use for retry logic and batch error semantics. Covers GLIDE-specific divergence from ioredis (which throws `redis.ReplyError`, `MaxRetriesPerRequestError`, etc. or emits via EventEmitter).

## Hierarchy

Subclass tree from `@valkey/valkey-glide`:

```
ValkeyError (abstract)           # Node's base is ValkeyError (NOT GlideError like Python)
├── ClosingError                 # client closed; create a new client
└── RequestError                 # catches everything below too
    ├── TimeoutError             # request exceeded requestTimeout (default 250ms)
    ├── ExecAbortError           # atomic batch aborted (WATCH conflict, MULTI errors)
    ├── ConnectionError          # temporary; GLIDE is auto-reconnecting
    └── ConfigurationError       # invalid config (TLS mismatch, RESP2+PubSub)
```

**Gotcha**: `instanceof RequestError` matches `TimeoutError`, `ConnectionError`, `ConfigurationError`, `ExecAbortError`. Order your `instanceof` checks specifics-first. Use `ValkeyError` only when you also want `ClosingError`.

## Divergence from ioredis

| ioredis | GLIDE Node |
|---------|-----------|
| `client.on('error', err => ...)` EventEmitter | No event emitter - errors surface per-promise, `await` catches them |
| `redis.ReplyError` for server errors | `RequestError` and subclasses |
| Connection errors swallowed + auto-recovered silently | `ConnectionError` surfaces on the command; GLIDE is reconnecting in the background |
| `MaxRetriesPerRequestError` after N retries | Reconnection is **infinite** - `BackoffStrategy.numberOfRetries` only caps the backoff curve length; client keeps retrying until close |
| `client.status` property exposes connection state | No public status property - observe via command success/failure or `getStatistics()` counters |

## Reconnection behavior

```typescript
connectionBackoff: {
    numberOfRetries: 5,       // caps the BACKOFF sequence length, not total retries
    factor: 100,              // ms base
    exponentBase: 2,
    jitterPercent: 20,        // optional
}
```

- Delay formula: `rand_jitter * factor * (exponentBase ** attempt)`, clamped at a ceiling.
- After `numberOfRetries` the delay plateaus and reconnection continues infinitely until close.
- Initial-connect permanent errors (`AuthenticationFailed`, `InvalidClientConfig`, `RESP3NotSupported`, plus string matches on `NOAUTH` / `WRONGPASS`) are not retried. After initial connect, the core keeps trying to reconnect regardless and surfaces `ConnectionError` per command until the server recovers or the client is closed.
- PubSub channels resubscribe automatically via the synchronizer.

## Failover and timeout

During cluster failover expect `ConnectionError` bursts for 1-5 seconds while the slot map refreshes. Retry is the right response.

Frequent `TimeoutError` usually indicates server load, not a too-tight timeout. GLIDE auto-extends the effective timeout for blocking commands (BLPOP/BRPOP/BLMOVE/BZPOPMAX/BZPOPMIN/BRPOPLPUSH/BLMPOP/BZMPOP and XREAD/XREADGROUP with BLOCK) by 0.5 s beyond the block duration - no tuning required.
