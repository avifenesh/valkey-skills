# Production deployment (Go)

Use when deploying GLIDE Go to production. Covers GLIDE-specific defaults and pitfalls that matter for operators. For basic setup examples see [features-connection](features-connection.md).

## One client per process

Do not pool `*Client` / `*ClusterClient`. The multiplexer is the pool. Creating N clients opens N sets of TCP connections to every node. `defer client.Close()` immediately after creation.

Use `WithLazyConnect(true)` if your app must start before Valkey is reachable - the first command pays the TCP connect cost.

## GLIDE Go defaults agents should know

| Knob | Default | Config |
|------|---------|--------|
| Request timeout | 250 ms | `WithRequestTimeout(d time.Duration)` |
| Connection timeout | 2000 ms | Advanced: `WithConnectionTimeout(d)` |
| Inflight request cap | 1000 (NOT configurable in Go at v2.3.1) | - |
| Topology check interval (cluster) | default | `WithPeriodicChecks` / `WithPeriodicChecksManualInterval` |
| Backoff retries | (infinite; cap only on sequence length) | `WithReconnectStrategy(NewBackoffStrategy(...))` |
| Protocol | RESP3 | via `protocol` enum in advanced config |
| TCP_NODELAY | true | advanced config `WithTcpNoDelay` |

Blocking-command timeout auto-extension: 0.5 s beyond the block duration. No tuning required.

## Timeout tuning

The 250 ms default is tight. Raise per-workload, not globally:

| Workload | Recommended |
|----------|-------------|
| Cache lookup (GET, HGET) | 250-500 ms |
| Writes (SET, HSET, ZADD) | 250-500 ms |
| Complex (SORT, SCAN, ZRANGEBYSCORE large) | 1-5 s |
| Lua scripts | 5-30 s |
| Blocking commands | Auto-extended - do not raise |

Go-idiomatic alternative: use `context.WithTimeout(ctx, d)` per-call. Context deadline takes precedence and is the standard Go pattern.

## Cluster: seed nodes and AZ affinity

Provide multiple seed addresses. Topology is auto-discovered.

`config.ReadFrom` values:

| Constant | Behavior |
|----------|----------|
| `config.Primary` | All reads to primary (default) |
| `config.PreferReplica` | Round-robin replicas, fall back to primary |
| `config.AzAffinity` | Same-AZ replicas preferred, then other replicas, then primary |
| `config.AzAffinityReplicaAndPrimary` | Same-AZ replicas, then same-AZ primary, then any replica, then primary - note `Replica` is singular in the user-facing constant |

AZ-affinity requires `WithClientAZ("<zone>")` AND the server exposing availability-zone metadata in `CLUSTER SHARDS` - otherwise falls back to primary.

## Batch options in production

Timeouts and retry strategies via `ExecWithOptions`:

```go
opts := pipeline.NewClusterBatchOptions().
    WithTimeout(5 * time.Second).
    WithRetryStrategy(*pipeline.NewClusterBatchRetryStrategy().
        WithRetryServerError(true).
        WithRetryConnectionError(true))
results, err := clusterClient.ExecWithOptions(ctx, *batch, false, *opts)
```

Retry strategies supported on non-atomic batches only. See [features-batching](features-batching.md) for hazards.

## Platform constraints

- **CGO required.** Needs a C toolchain and glibc 2.17+. Alpine needs `musl-gcc` or `CGO_ENABLED=1` with the right toolchain.
- **No static binary.** Go + GLIDE produces a dynamically linked executable.
- **Cross-compilation** needs a matching C toolchain for the target (`CC=x86_64-linux-gnu-gcc` etc.).
- **Proxies / connection inspectors**: GLIDE sends `CLIENT SETNAME`, `CLIENT SETINFO`, `INFO REPLICATION` during setup. Transparent proxies that strip these break topology detection.
