---
name: valkey-dev
description: "Use when contributing to the Valkey server source - C internals, event loop, data structures, cluster, replication, persistence, memory, threading, modules, scripting, tests, build. Only what diverges from Redis or is genuinely novel; agent-trained-on-Redis knowledge is assumed. Not for app development (valkey) or ops (valkey-ops)."
version: 2.0.0
argument-hint: "[subsystem or source path]"
---

# Valkey Contributor Reference

**This skill does not replace reasoning and exploring the relevant code. It is a tool to find the nuance faster and sharper.**

Organized by what you're working on. Each file covers a coherent work area; Redis-baseline behavior is assumed and not repeated. All files target `unstable`.

## Route by work area

| Working on... | File | Grep-friendly topics inside |
|---------------|------|-----------------------------|
| Client bytes, RESP parsing, command dispatch, client struct, I/O offload, reply buffers, transports, RDMA, reply-ordering rules, shared query buffer aliasing | `reference/networking.md` | `## Client fields for I/O-thread offload`, `## Shared query buffer`, `## I/O-thread dispatch`, `## Command table uses hashtable`, `## -REDIRECT during coordinated failover`, `## Command dispatch invariants`, `## I/O-thread offload invariants`, `## Key prefetching`, `## Transport layer invariants`, `## RDMA transport` |
| Event loop hooks, I/O threads, BIO workers, Ignition/Cooldown, batch prefetching, `poll_mutex`, `custompoll`, atomics & thread ownership, main/IO boundary ownership table | `reference/event-loop.md` | `## ae reactor additions`, `## beforeSleep / afterSleep integration with I/O threads`, `## Main/IO ownership invariants`, `## Atomic usage and memory ordering`, `## Lazyfree and BIO job ordering`, `## Shutdown, teardown, signal handlers`, `## Batch key prefetching`, `## Event-loop / client-state invariants` |
| `hashtable`, `kvstore`, `robj`, encoding transitions, listpack/quicklist/skiplist/rax/sds, `vset`, multi-DB, `keys_with_volatile_items`, rehash cursor, iterator safety, two-phase insert, 5-window iterator taxonomy | `reference/data-structures.md` | `## Iterator-invariant taxonomy`, `## Keyspace: kvstore per DB`, `## kvstore`, `## Hashtable`, `## Object lifecycle`, `## Encoding transitions`, `## Skiplist`, `## vset`, `## Hash field entry` |
| Cluster slot migration (traditional OR atomic), cluster failover, Sentinel coordinated failover, MOVED/ASK, cluster bus wire format, gossip rules, CLUSTERSCAN fingerprint | `reference/ha.md` | `## Cluster shape`, `## Cluster bus`, `## Failover`, `## Slot migration`, `## Gossip`, `## SCAN cross-node`, `## CLUSTER SLOT-STATS`, `## Sentinel` |
| RDB format, RDB types, AOF, replication, dual-channel, `VALKEY080` magic, `RDB_TYPE_HASH_2`, TTL absolute-timestamp propagation, replicate-as-DEL contract, write-path classification flowchart | `reference/data-durability.md` | `## RDB`, `## AOF`, `## Replication`, `## Dual-channel replication`, `## Fork machinery` |
| EVAL, FUNCTION, scripting-engine ABI, module API, `ValkeyModule_*`, custom data types, Rust SDK, ABI versioning, `current_client` vs `executing_client` | `reference/scripting-and-modules.md` | `## Scripting dispatch`, `## Scripting engine ABI`, `## Module lifecycle`, `## Custom data types`, `## Key API, blocking, and threading`, `## Lua engine`, `## Rust SDK` |
| MULTI/EXEC, blocking commands (BLPOP etc.), pub/sub, keyspace notifications, `hexpired`, `__redis__:invalidate`, notify-before-addReply ordering | `reference/client-commands.md` | `## MULTI / EXEC`, `## Blocking operations`, `## Pub/Sub`, `## Keyspace Notifications` |
| Allocator (zmalloc/valkey_malloc), eviction, lazy-free defaults, active defrag, expiry cycle, per-field TTL reclaim, read-path-doesn't-reclaim rule, write-path volatile-items untrack | `reference/memory.md` | `## zmalloc`, `## Eviction`, `## Lazy free`, `## Active defragmentation`, `## Expiry`, `### Read-path discipline`, `### Write-path propagation`, `### Events, RDB, role transitions` |
| CommandLog, SLOWLOG, Latency monitor, CLIENT TRACKING, DEBUG | `reference/monitoring.md` | `## Commandlog`, `## Latency Monitor`, `## Client Tracking` |
| ACL (db selectors, `%R~`/`%W~`), TLS auto-reload, `tls-auth-clients-user` | `reference/security.md` | `## ACL`, `## TLS` |
| Build (`make`, `cmake`, `BUILD_TLS`, `BUILD_RDMA`), sanitizers, TCL tests, gtest unit tests, CI, CONFIG registration, renamed configs, DCO/clang-format | `reference/devex.md` | `## Critical correctness rules`, `## Code rules`, `## Test rules`, `## Sanitizer builds`, `## Config system` |

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
