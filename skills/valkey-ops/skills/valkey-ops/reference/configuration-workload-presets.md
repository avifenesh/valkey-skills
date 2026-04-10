# Configuration Presets by Workload

Use when configuring Valkey for a specific use case - cache, primary store, session, queue, rate limiter.

Standard Redis workload presets apply. See Redis docs for general guidance on persistence, eviction, and connection settings.

## Valkey-Specific Parameter Names

The key difference from Redis: Valkey uses `commandlog` instead of `slowlog`.

| Redis | Valkey |
|-------|--------|
| `slowlog-log-slower-than` | `commandlog-execution-slower-than` (alias works) |
| `slowlog-max-len` | `commandlog-slow-execution-max-len` (alias works) |

Valkey also adds request/reply size logging:
- `commandlog-request-larger-than` (default 1MB)
- `commandlog-reply-larger-than` (default 1MB)

## Additional Valkey Parameters

`maxmemory-clients` - caps aggregate client buffer memory (absent in Redis):

```
maxmemory-clients 5%    # recommended for all workloads
```

`active-expire-effort` - controls expiration aggressiveness (default 1):

```
active-expire-effort 3   # for session stores with frequent TTL expiry
```

## Rate Limiter Preset Note

```
commandlog-execution-slower-than 5000   # 5ms threshold
```

Use `commandlog` (not `slowlog`) in Valkey configs. The `slowlog-*` aliases still work at runtime.
