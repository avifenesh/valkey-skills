# Lazy-Free

Use when tuning background deletion or reasoning about `DEL` vs `UNLINK` semantics.

## All five defaults flipped to `yes` in Valkey

| Parameter | Valkey default | Redis default |
|-----------|---------------|---------------|
| `lazyfree-lazy-eviction` | `yes` | `no` |
| `lazyfree-lazy-expire` | `yes` | `no` |
| `lazyfree-lazy-server-del` | `yes` | `no` |
| `lazyfree-lazy-user-del` | `yes` | `no` |
| `lazyfree-lazy-user-flush` | `yes` | `no` |

All runtime-modifiable. The flip means `DEL`, `FLUSH*`, maxmemory eviction, TTL expiry, and server-internal replacements (e.g., `SET` over existing key, `RENAME` target) all go to BIO lazy-free by default. Without this, freeing a large sorted set or hash on the main thread produces latency spikes measurable in hundreds of ms.

## What each covers

- **`lazy-eviction`** - keys removed because of `maxmemory-policy`.
- **`lazy-expire`** - both active (periodic expire cycle) and lazy (on-access) TTL expiry.
- **`lazy-server-del`** - server-internal implicit deletions (`RENAME` target, `SET` replacing old value, `DEBUG RELOAD`'s intermediate swaps, etc.).
- **`lazy-user-del`** - user-issued `DEL` command. With `yes`, `DEL` behaves like `UNLINK`.
- **`lazy-user-flush`** - `FLUSHDB` / `FLUSHALL` without explicit `ASYNC` behave as if `ASYNC` were given.

## `DEL` vs `UNLINK` in Valkey-default config

With `lazyfree-lazy-user-del yes`, they're operationally identical - both unlink the key synchronously (O(1)) and queue the memory reclaim to BIO.

Still, prefer explicit `UNLINK` in application code:
- Intent is clear at the call site.
- Protects against a future `CONFIG SET lazyfree-lazy-user-del no` silently re-introducing blocking deletes.

## `FLUSH*` modifiers

```
FLUSHDB ASYNC     # explicit - always background, regardless of config
FLUSHDB SYNC      # explicit - always blocking, regardless of config
FLUSHDB           # follows lazyfree-lazy-user-flush setting
```

`ASYNC`/`SYNC` modifiers override the config for that invocation only.

## Observability

```
valkey-cli INFO stats | grep lazyfree
# lazyfree_pending_objects:<N>
```

`N` is the queue of keys unlinked but not yet freed. Under sustained delete pressure, `N` climbs and BIO can't keep up - memory reclaim lags observable from `used_memory` not tracking `used_memory_peak` quickly. Usually transient; if it stays elevated, check BIO thread CPU.

## Replication behavior

Lazy-free is local to each node. When `lazyfree-lazy-user-del` rewrites `DEL` into an unlink+BIO-free, the **replication stream still contains `DEL`** - replicas receive the command and apply their own lazyfree settings. So a replica with `lazyfree-lazy-user-del no` will block on large-key DEL even though the primary didn't. Keep replica settings consistent with primary.

## When to disable

Almost never in production. Rare cases:

- Deterministic memory accounting (embedded / IoT).
- Benchmarks where BIO-thread CPU interferes with measurement.
- Debugging memory issues and you need synchronous free for reproducibility.
