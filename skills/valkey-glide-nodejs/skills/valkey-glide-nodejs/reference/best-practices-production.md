# Production deployment (Node.js)

Use when deploying GLIDE Node to production. Covers GLIDE-specific defaults and pitfalls that matter for operators. For basic setup examples see [features-connection](features-connection.md).

## One client per process

Do not pool `GlideClient` / `GlideClusterClient`. The multiplexer is the pool. Creating N clients opens N sets of TCP connections to every node and defeats the connection-state tracking the core does.

Use `lazyConnect: true` if your app must start before Valkey is reachable - the first command pays the connection cost. Always call `client.close()` on shutdown (synchronous - returns `void`, not a Promise); pending promises get `ClosingError`.

## GLIDE defaults agents should know

| Knob | Default | Config |
|------|---------|--------|
| Request timeout | 250 ms | `requestTimeout` |
| Connection timeout | 2000 ms | `advancedConfiguration.connectionTimeout` |
| Inflight request cap | 1000 | `inflightRequestsLimit` |
| Topology check interval (cluster) | default configs | `periodicChecks: { duration_in_sec: n }` for manual; note `duration_in_sec` is snake_case |
| Backoff retries | (infinite; cap only on sequence length) | `connectionBackoff` |
| Protocol | RESP3 | `protocol: ProtocolVersion.RESP2` to downgrade |
| TCP_NODELAY | true | `advancedConfiguration.tcpNoDelay` |
| Default decoder | `Decoder.String` | `defaultDecoder: Decoder.Bytes` for Buffer returns |

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

## Cluster: seed nodes and AZ affinity

Provide multiple seed addresses for redundancy. Topology is auto-discovered.

`readFrom` strategies:

| Strategy | Behavior |
|----------|----------|
| `"primary"` | All reads to primary (default) |
| `"preferReplica"` | Round-robin replicas, fall back to primary |
| `"AZAffinity"` | Same-AZ replicas preferred, then other replicas, then primary |
| `"AZAffinityReplicasAndPrimary"` | Same-AZ replicas, then same-AZ primary, then any replica, then primary |

AZ-affinity strategies require `clientAz` AND the server exposing availability-zone metadata in `CLUSTER SHARDS` - otherwise falls back to primary.

## OpenTelemetry

Initialize once, globally, before creating any clients:

```typescript
import { OpenTelemetry } from "@valkey/valkey-glide";

OpenTelemetry.init({
    traces: { endpoint: "http://otel-collector:4317", samplePercentage: 1 },
    metrics: { endpoint: "http://otel-collector:4317" },
    flushIntervalMs: 5000,
});
```

Rough sampling rates: 1-2% prod, 5-10% staging, 50-100% debugging.

## Platform constraints

- **glibc 2.17+** required on Linux. Alpine (musl) is NOT supported out of the box - use Debian/Ubuntu-based images. Prebuilt wheels for musl exist in some distributions but are not part of the official matrix.
- **Native binding**: `@valkey/valkey-glide` ships a platform-specific `@valkey/valkey-glide-<os>-<arch>` native package. Lockfile regeneration on different OS/arch combos can pull the wrong native binary - keep `npm ci` in CI aligned with the target platform.
- **Proxies / connection inspectors**: GLIDE sends `CLIENT SETNAME`, `CLIENT SETINFO`, `INFO REPLICATION` during setup. Transparent proxies that strip or rewrite these will break topology detection.
- **Protocol**: RESP3 is the default. RESP2 is accepted but static PubSub subscriptions require RESP3 and raise `ConfigurationError` otherwise.
