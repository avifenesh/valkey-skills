---
name: valkey-dev
description: "Use when contributing to the Valkey server source - C internals, event loop, data structures, cluster, replication, persistence, memory, threading, modules, scripting, tests, build. Only what diverges from Redis or is genuinely novel; agent-trained-on-Redis knowledge is assumed. Not for app development (valkey) or ops (valkey-ops)."
version: 2.0.0
argument-hint: "[subsystem or source path]"
---

# Valkey Contributor Reference

Organized by what you're working on. Each file covers a coherent work area; Redis-baseline behavior is assumed and not repeated. All files target `unstable`.

## Route by work area

| Working on... | File | Grep-friendly topics inside |
|---------------|------|-----------------------------|
| Client bytes, RESP parsing, command dispatch, client struct, I/O offload, reply buffers, transports, RDMA | `reference/networking.md` | `## RDMA transport`, `## Transport layer`, `## Command table`, `## -REDIRECT`, `## Shared query buffer`, `## Key prefetching` |
| Event loop hooks, I/O threads, BIO workers, Ignition/Cooldown, batch prefetching, `poll_mutex`, `custompoll` | `reference/event-loop.md` | `## I/O threads`, `## BIO`, `## Batch key prefetching`, `## beforeSleep / afterSleep` |
| `hashtable`, `kvstore`, `robj`, encoding transitions, listpack/quicklist/skiplist/rax/sds, `vset`, multi-DB, `keys_with_volatile_items` | `reference/data-structures.md` | `## kvstore`, `## Hashtable`, `## Object lifecycle`, `## Encoding transitions`, `## vset`, `## Skiplist`, `## Dict (legacy)` |
| Cluster slot migration (traditional OR atomic), cluster failover, Sentinel coordinated failover, MOVED/ASK, `cluster_migrateslots.c` | `reference/ha.md` | `## Cluster shape`, `## Cluster failover`, `## Slot migration`, `### Atomic slot migration`, `## Sentinel` |
| RDB format, RDB types, AOF, replication, dual-channel, `VALKEY080` magic, `RDB_TYPE_HASH_2` | `reference/data-durability.md` | `## RDB`, `## AOF`, `## Replication`, `## Dual-channel replication` |
| EVAL, FUNCTION, scripting-engine ABI, module API, `ValkeyModule_*`, custom data types, Rust SDK | `reference/scripting-and-modules.md` | `## Scripting engine ABI`, `## Module lifecycle`, `## Custom data types`, `## Rust SDK` |
| MULTI/EXEC, blocking commands (BLPOP etc.), pub/sub, keyspace notifications, `hexpired`, `__redis__:invalidate` | `reference/client-commands.md` | `## MULTI / EXEC`, `## Blocking`, `## Pub/Sub`, `## Keyspace Notifications` |
| Allocator (zmalloc/valkey_malloc), eviction, lazy-free defaults, active defrag, expiry cycle, per-field TTL reclaim | `reference/memory.md` | `## Active defragmentation`, `## Lazy free`, `## Eviction`, `## Expiry`, `## zmalloc` |
| CommandLog, SLOWLOG, Latency monitor, CLIENT TRACKING, DEBUG | `reference/monitoring.md` | `## Commandlog`, `## Latency Monitor`, `## Client Tracking` |
| ACL (db selectors, `%R~`/`%W~`), TLS auto-reload, `tls-auth-clients-user` | `reference/security.md` | `## ACL`, `## TLS` |
| Build (`make`, `cmake`, `BUILD_TLS`, `BUILD_RDMA`), sanitizers, TCL tests, gtest unit tests, CI, CONFIG registration, renamed configs, DCO/clang-format/governance | `reference/devex.md` | `## Build`, `## Sanitizer builds`, `## TCL Test Framework`, `## C++ Unit Tests`, `## CI`, `## Config system`, `## Contribution workflow` |

## Quick start

```sh
make -j$(nproc)                          # build
./runtest --verbose --tags -slow         # core integration tests
./runtest-cluster                        # legacy cluster tests
./runtest-moduleapi                      # module API tests
./runtest-sentinel                       # Sentinel tests
make test-unit                           # C++ gtest unit tests
make SANITIZER=address                   # ASan (force MALLOC=libc)
```

Details and non-obvious knobs: `reference/devex.md`.

## Critical rules

1. PRs target `unstable`. DCO sign-off (`git commit -s`) is required. `clang-format-18` diff fails CI.
2. Tests are non-negotiable - TCL integration or gtest unit, matching what you changed.
3. When adding / modifying a command, `src/commands/*.json` must regenerate `commands.def` cleanly (`make commands.def`).
4. Writing reply handlers? Check `c->resp` and use the RESP3-aware `addReplyMapLen` / `addReplySetLen` / `addReplyPushLen` / etc. Don't branch in callers.
5. If you're adding a new allocation owned by a type (defrag, RDB, AOF, module), implement the `dismissObject` / defrag / RDB callbacks - silent leaks in fork children are hard to find later.

## Common grep hazards

These names differ from Redis; an agent trained on Redis would search for the wrong token:

- `redisCommand` → **gone**; struct is `struct serverCommand`. Hashtable not dict: `server.commands = hashtableCreate(&commandSetType)`.
- `zmalloc` / `zfree` → `#define`d to `valkey_malloc` / `valkey_free` (stack traces show the `valkey_*` name).
- `RedisModule_*` → `ValkeyModule_*` (compat shim `redismodule.h` is pinned at Redis 7.2.4).
- Replication configs: `slaveof` / `slave-priority` / `masteruser` / `masterauth` → `replicaof` / `replica-priority` / `primaryuser` / `primaryauth`.
- Hashtable design: **bucket chaining**, not open-addressing, not Robin Hood. 64-byte buckets, 7 entries + chain pointer.
- Invalidation channel still named `__redis__:invalidate` (not `__valkey__:*`).
- `adjustIOThreadsByEventLoad` **does not exist**. Real call sites: `IOThreadsBeforeSleep` / `IOThreadsAfterSleep` with Ignition/Cooldown policy.
- `events-per-io-thread` is deprecated (in `deprecated_configs[]`). The Ignition/Cooldown CPU-sample policy replaced the old event-count heuristic.
- Embed-string budget is **128 bytes** (2 cache lines via `shouldEmbedStringObject`), not the old `OBJ_ENCODING_EMBSTR_SIZE_LIMIT 44`.
