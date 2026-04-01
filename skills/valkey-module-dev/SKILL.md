---
name: valkey-module-dev
description: "Use when building custom Valkey modules in C or Rust. Covers ValkeyModule_* API, command registration, custom data types, RDB/AOF persistence, blocking commands, events, cluster, threading, defrag, scripting engines, and testing. Not for using existing modules (valkey-modules) or contributing to the server (valkey-dev)."
version: 1.0.0
argument-hint: "[API area or task]"
---

# Valkey Module Development Reference

45 source-verified reference docs covering the complete ValkeyModule_* C API for building custom Valkey modules. Organized by lifecycle, commands, data types, events, and advanced APIs. All function signatures and behaviors verified against the Valkey 9.0.3 source (`src/module.c`, `src/valkeymodule.h`).

Browse by category below or ask about a specific API. Each link leads to a focused reference doc with function signatures, parameters, return values, and usage patterns.

## Routing

- Module skeleton / OnLoad / Init / startup -> Lifecycle (module-loading)
- Module options / capabilities / IO error handling -> Lifecycle (module-options)
- Context object / server state / replication role -> Lifecycle (context)
- Memory allocation / pooling / auto-memory / tracking -> Lifecycle (memory)
- Logging / error reporting / latency samples -> Lifecycle (logging)
- Shared API / inter-module dependencies -> Lifecycle (api-importing)
- Server version / time / database selection -> Lifecycle (server-info)
- Register commands / flags / key specs / subcommands -> Commands (registration)
- Reply building / arrays / maps / RESP2/RESP3 -> Commands (reply-building)
- ValkeyModuleString / create / parse / compare -> Commands (string-objects)
- Open keys / type check / TTL / expiry -> Commands (key-generic)
- String key values / DMA / read-write -> Commands (key-string)
- List push / pop / index / insert / delete -> Commands (key-list)
- Hash fields / field existence / streams -> Commands (key-hash-stream)
- Sorted set add / remove / score / range -> Commands (key-sorted-set)
- Custom data type / type name / callbacks -> Data Types (registration)
- RDB save / load / serialization primitives -> Data Types (rdb-callbacks)
- AOF rewrite / EmitAOF / format specifiers -> Data Types (aof-rewrite)
- Digest / DEBUG DIGEST / replica verification -> Data Types (digest)
- IO context / aux data / global state / COPY support / v2 callbacks -> Data Types (io-context)
- RDB stream / full save/load / backup -> Data Types (rdb-stream)
- Block client / background work / timeout -> Events (blocking-clients)
- Block on keys / BLPOP-like / key readiness -> Events (blocking-on-keys)
- Keyspace notifications / subscribe / emit -> Events (keyspace-notifications)
- Server events / role change / shutdown / config -> Events (server-events)
- Timers / periodic callbacks / deferred ops -> Events (timers)
- Event loop / file descriptors / yield CPU -> Events (eventloop)
- ValkeyModule_Call / execute commands / replies -> Advanced (calling-commands)
- Replicate / propagation / AOF + replicas -> Advanced (replication)
- ACL / auth / permissions / module users -> Advanced (acl)
- Cluster messaging / node info / slots -> Advanced (cluster)
- Command filter / intercept / rewrite -> Advanced (command-filter)
- Module config / CONFIG SET/GET / typed params -> Advanced (module-configs)
- INFO sections / custom metrics / crash report -> Advanced (info-callbacks)
- Client info / ID / name / ACL user / memory -> Advanced (client-info)
- Thread safe context / GIL / background thread -> Advanced (threading)
- Pub/Sub / publish / shard channels -> Advanced (pubsub)
- Dictionary / radix tree / range iteration -> Advanced (dictionary)
- Scan / keyspace iteration / cursor -> Advanced (scan)
- Fork / child process / background compute -> Advanced (fork)
- LRU / LFU / eviction / mem_usage / idle time -> Advanced (lru-lfu)
- Defrag / DefragAlloc / cooperative / cursors -> Cross-Cutting (defrag)
- Scripting engine / custom language / EVAL -> Cross-Cutting (scripting-engine)
- Testing / Tcl harness / CI / runtest-moduleapi -> Cross-Cutting (testing)
- Rust SDK / valkeymodule-rs / Cargo -> Cross-Cutting (rust-sdk)

## Quick Start

```c
#include "valkeymodule.h"

int HelloCmd(ValkeyModuleCtx *ctx, ValkeyModuleString **argv, int argc) {
    VALKEYMODULE_NOT_USED(argv);
    if (argc != 1) return ValkeyModule_WrongArity(ctx);
    return ValkeyModule_ReplyWithSimpleString(ctx, "Hello from my module!");
}

int ValkeyModule_OnLoad(ValkeyModuleCtx *ctx,
                        ValkeyModuleString **argv, int argc) {
    if (ValkeyModule_Init(ctx, "mymod", 1, VALKEYMODULE_APIVER_1)
        == VALKEYMODULE_ERR)
        return VALKEYMODULE_ERR;

    if (ValkeyModule_CreateCommand(ctx, "mymod.hello", HelloCmd,
                                   "readonly", 0, 0, 0) == VALKEYMODULE_ERR)
        return VALKEYMODULE_ERR;

    return VALKEYMODULE_OK;
}
```

```bash
gcc -shared -fPIC -o mymod.so mymod.c -I /path/to/valkey/src
valkey-server --loadmodule ./mymod.so
valkey-cli mymod.hello
# "Hello from my module!"
```

## Critical Rules

1. **Call ValkeyModule_Init first** - must be the first API call in OnLoad; all function pointers are NULL until Init succeeds
2. **Return VALKEYMODULE_OK or VALKEYMODULE_ERR** - every command handler and OnLoad must return one of these
3. **Type names are exactly 9 characters** - custom data type names must be 9 bytes with the first character encoding a version
4. **Never call non-thread-safe APIs from background threads** - only use thread-safe context APIs (Lock/Unlock, ReplyWithError, Log) outside the main thread
5. **Replicate explicitly** - module writes are not automatically propagated; call Replicate or ReplicateVerbatim in every write command
6. **Set correct command flags** - missing `write` flag on a mutating command causes silent replication/AOF failures; missing `readonly` allows writes during replication
7. **Test with runtest-moduleapi** - use `./runtest-moduleapi --single unit/moduleapi/<test>` for module integration tests

## Lifecycle and Core

| Topic | Reference |
|-------|-----------|
| OnLoad entry point, ValkeyModule_Init, dlopen, MODULE LOAD/UNLOAD | [module-loading](reference/lifecycle/module-loading.md) |
| Module capability flags - IO errors, diskless, nested notifications | [module-options](reference/lifecycle/module-options.md) |
| Context object - server state, replication role, OOM detection | [context](reference/lifecycle/context.md) |
| Heap allocation, pool allocation, auto-memory, usage tracking | [memory](reference/lifecycle/memory.md) |
| Log messages, error reporting, latency samples, assertions | [logging](reference/lifecycle/logging.md) |
| Shared API export/import between modules | [api-importing](reference/lifecycle/api-importing.md) |
| Server version, time, database selection, random data, arity errors | [server-info](reference/lifecycle/server-info.md) |

## Commands and Keys

| Topic | Reference |
|-------|-----------|
| CreateCommand, flags, key specs, subcommands, ACL categories | [registration](reference/commands/registration.md) |
| ReplyWith* functions, arrays, maps, sets, RESP2/RESP3 | [reply-building](reference/commands/reply-building.md) |
| ValkeyModuleString create, parse, compare, append, format | [string-objects](reference/commands/string-objects.md) |
| OpenKey, key type checking, TTL, expiry, key deletion | [key-generic](reference/commands/key-generic.md) |
| String values - DMA read/write, StringSet, StringTruncate | [key-string](reference/commands/key-string.md) |
| List push, pop, index access, insert, delete | [key-list](reference/commands/key-list.md) |
| Hash field read/write, field existence, stream add/iterate/trim | [key-hash-stream](reference/commands/key-hash-stream.md) |
| Sorted set add, remove, score query, range iteration | [key-sorted-set](reference/commands/key-sorted-set.md) |

## Data Types and Persistence

| Topic | Reference |
|-------|-----------|
| RegisterType, 9-char name, ValkeyModuleTypeMethods callbacks | [registration](reference/data-types/registration.md) |
| rdb_save/rdb_load callbacks, Save/Load primitives, versioning | [rdb-callbacks](reference/data-types/rdb-callbacks.md) |
| aof_rewrite callback, EmitAOF, format specifiers | [aof-rewrite](reference/data-types/aof-rewrite.md) |
| digest callback, DigestAddStringBuffer, ordering patterns | [digest](reference/data-types/digest.md) |
| KeyOptCtx accessors, aux_load/aux_save, COPY support, v2 callbacks, IO errors | [io-context](reference/data-types/io-context.md) |
| Programmatic RDB save/load, backup/restore, migration tools | [rdb-stream](reference/data-types/rdb-stream.md) |

## Events and Blocking

| Topic | Reference |
|-------|-----------|
| BlockClient for background work, timeout/disconnect handling | [blocking-clients](reference/events/blocking-clients.md) |
| Block on keys until data arrives - BLPOP-like commands | [blocking-on-keys](reference/events/blocking-on-keys.md) |
| Keyspace event subscription, custom notifications, safe writes | [keyspace-notifications](reference/events/keyspace-notifications.md) |
| Server lifecycle events - role change, persistence, shutdown | [server-events](reference/events/server-events.md) |
| Millisecond timers, periodic tasks, retry logic, deferred ops | [timers](reference/events/timers.md) |
| File descriptor monitoring, one-shot callbacks, CPU yielding | [eventloop](reference/events/eventloop.md) |

## Advanced APIs

| Topic | Reference |
|-------|-----------|
| ValkeyModule_Call, format specifiers, CallReply, async calls | [calling-commands](reference/advanced/calling-commands.md) |
| Replicate, ReplicateVerbatim, propagation to replicas and AOF | [replication](reference/advanced/replication.md) |
| ACL permission checks, module users, auth callbacks | [acl](reference/advanced/acl.md) |
| Cluster messaging, node discovery, slot computation | [cluster](reference/advanced/cluster.md) |
| Command filter registration, argument inspection/modification | [command-filter](reference/advanced/command-filter.md) |
| CONFIG SET/GET integration, typed parameters, validation | [module-configs](reference/advanced/module-configs.md) |
| Custom INFO sections, dict fields, crash report, GetServerInfo | [info-callbacks](reference/advanced/info-callbacks.md) |
| Client ID, name, ACL username, memory pressure, redaction | [client-info](reference/advanced/client-info.md) |
| Thread-safe contexts, GIL locking, background threads | [threading](reference/advanced/threading.md) |
| PublishMessage, shard channels, cluster propagation | [pubsub](reference/advanced/pubsub.md) |
| In-memory radix tree dictionary, range scans, prefix matching | [dictionary](reference/advanced/dictionary.md) |
| Keyspace scanning, element scanning within keys, cursors | [scan](reference/advanced/scan.md) |
| Background child process via fork, heartbeat, COW reporting | [fork](reference/advanced/fork.md) |
| LRU/LFU eviction APIs, idle time, access frequency, mem_usage | [lru-lfu](reference/advanced/lru-lfu.md) |

## Cross-Cutting

| Topic | Reference |
|-------|-----------|
| Active defragmentation for module types, cursors, cooperative slicing | [defrag](reference/defrag.md) |
| Custom scripting engine registration, compile/execute callbacks | [scripting-engine](reference/scripting-engine.md) |
| Module testing with Tcl harness, CI setup, runtest-moduleapi | [testing](reference/testing.md) |
| Rust SDK (valkeymodule-rs), Cargo setup, C-to-Rust mapping | [rust-sdk](reference/rust-sdk.md) |
