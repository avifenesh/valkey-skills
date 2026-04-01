# Replication - Replicate, ReplicateVerbatim, Propagation Control

Use when propagating module command effects to replicas and AOF, choosing between explicit replication and verbatim forwarding.

Source: `src/module.c` (lines 3671-3778), `src/valkeymodule.h`

## Contents

- [ValkeyModule_Replicate](#valkeymodule_replicate)
- [ValkeyModule_ReplicateVerbatim](#valkeymodule_replicateverbatim)
- [Replication via ValkeyModule_Call](#replication-via-valkeymodule_call)
- [Choosing a Strategy](#choosing-a-strategy)
- [Propagation Targets](#propagation-targets)
- [Thread-Safe Context Behavior](#thread-safe-context-behavior)

---

## ValkeyModule_Replicate

```c
int ValkeyModule_Replicate(ValkeyModuleCtx *ctx,
                           const char *cmdname,
                           const char *fmt, ...);
```

Replicates a synthetic command to replicas and AOF. The format string uses the same specifiers as `ValkeyModule_Call`:

| Specifier | Type | Description |
|-----------|------|-------------|
| `c` | `char *` | Null-terminated C string |
| `s` | `ValkeyModuleString *` | Module string object |
| `b` | `char *, size_t` | Binary buffer with length |
| `l` | `long long` | Integer value |
| `v` | `ValkeyModuleString **, size_t` | Vector of strings with count |
| `A` | (flag) | Suppress AOF propagation |
| `R` | (flag) | Suppress replica propagation |

Returns `VALKEYMODULE_OK` on success, `VALKEYMODULE_ERR` on invalid format or unknown command.

```c
/* Replicate a SET command to replicas and AOF */
ValkeyModule_Replicate(ctx, "SET", "sc", argv[1], "new_value");

/* Replicate to replicas only, skip AOF */
ValkeyModule_Replicate(ctx, "SET", "Asc", argv[1], "new_value");

/* Replicate to AOF only, skip replicas */
ValkeyModule_Replicate(ctx, "SET", "Rsc", argv[1], "new_value");
```

Commands replicated with `ValkeyModule_Replicate` are wrapped in a MULTI/EXEC block along with any commands replicated via `ValkeyModule_Call` with the `!` flag. The `Call` replications appear first, followed by `Replicate` calls, all before the EXEC.

## ValkeyModule_ReplicateVerbatim

```c
int ValkeyModule_ReplicateVerbatim(ValkeyModuleCtx *ctx);
```

Replicates the original client command exactly as received - same command name, same arguments. Always returns `VALKEYMODULE_OK`.

```c
int MyCommand(ValkeyModuleCtx *ctx, ValkeyModuleString **argv, int argc) {
    /* Do work, then forward the exact command */
    ValkeyModule_ReplicateVerbatim(ctx);
    return ValkeyModule_ReplyWithSimpleString(ctx, "OK");
}
```

This is not wrapped in MULTI/EXEC. Do not mix `ReplicateVerbatim` with `Replicate` in the same command execution.

## Replication via ValkeyModule_Call

The `!` flag on `ValkeyModule_Call` propagates the called command itself:

```c
/* Execute and replicate SET to both AOF and replicas */
ValkeyModule_Call(ctx, "SET", "!sc", argv[1], "value");

/* Execute and replicate to replicas only */
ValkeyModule_Call(ctx, "SET", "!Asc", argv[1], "value");

/* Execute and replicate to AOF only */
ValkeyModule_Call(ctx, "SET", "!Rsc", argv[1], "value");
```

Nested `ValkeyModule_Call` replication is suppressed to prevent duplication. If module1 calls module2's command without `!`, and module2 internally uses `ValkeyModule_Call` with `!`, only the outer module's replication strategy applies.

## Choosing a Strategy

| Strategy | When to Use |
|----------|-------------|
| `ReplicateVerbatim` | Command is deterministic and can be re-executed as-is on replicas |
| `Replicate` | Command is not deterministic, or you need to replicate different commands than what was received |
| `Call` with `!` | You are calling standard Valkey commands and want them individually replicated |

Common patterns:

**Deterministic command** - use `ReplicateVerbatim`:
```c
/* MYMOD.INCR key - just wraps INCR with extra logic */
int MyIncr(ValkeyModuleCtx *ctx, ValkeyModuleString **argv, int argc) {
    ValkeyModuleCallReply *r = ValkeyModule_Call(ctx, "INCR", "s", argv[1]);
    long long val = ValkeyModule_CallReplyInteger(r);
    ValkeyModule_FreeCallReply(r);
    ValkeyModule_ReplicateVerbatim(ctx);
    return ValkeyModule_ReplyWithLongLong(ctx, val);
}
```

**Non-deterministic command** - use `Replicate` with resolved values:
```c
/* MYMOD.SETTIME key - stores current timestamp */
int MySetTime(ValkeyModuleCtx *ctx, ValkeyModuleString **argv, int argc) {
    long long now = ValkeyModule_Milliseconds();
    ValkeyModule_Call(ctx, "SET", "sl", argv[1], now);
    /* Replicate the resolved value, not the command */
    ValkeyModule_Replicate(ctx, "SET", "sl", argv[1], now);
    return ValkeyModule_ReplyWithLongLong(ctx, now);
}
```

**Multiple operations** - use `Call` with `!`:
```c
/* MYMOD.SWAP key1 key2 */
int MySwap(ValkeyModuleCtx *ctx, ValkeyModuleString **argv, int argc) {
    ValkeyModuleCallReply *r1 = ValkeyModule_Call(ctx, "GET", "s", argv[1]);
    ValkeyModuleCallReply *r2 = ValkeyModule_Call(ctx, "GET", "s", argv[2]);
    /* Both SETs are replicated within MULTI/EXEC */
    ValkeyModule_Call(ctx, "SET", "!ss", argv[1],
        ValkeyModule_CreateStringFromCallReply(r2));
    ValkeyModule_Call(ctx, "SET", "!ss", argv[2],
        ValkeyModule_CreateStringFromCallReply(r1));
    ValkeyModule_FreeCallReply(r1);
    ValkeyModule_FreeCallReply(r2);
    return ValkeyModule_ReplyWithSimpleString(ctx, "OK");
}
```

## Propagation Targets

| Flags | AOF | Replicas |
|-------|-----|----------|
| (none) | Yes | Yes |
| `A` | No | Yes |
| `R` | Yes | No |

## Thread-Safe Context Behavior

When calling `ValkeyModule_Replicate` from a thread-safe context, the behavior differs: the command is inserted into the AOF and replication stream immediately without MULTI/EXEC wrapping. This is because thread-safe contexts can live indefinitely and be locked/unlocked at will.

## See Also

- [calling-commands.md](calling-commands.md) - ValkeyModule_Call format specifiers including `!`, `A`, `R` flags
- [threading.md](threading.md) - Thread-safe context behavior for Replicate calls
- [../events/server-events.md](../events/server-events.md) - ReplicationRoleChanged, ReplicaChange, and PrimaryLinkChange events
- [../data-types/aof-rewrite.md](../data-types/aof-rewrite.md) - AOF rewrite callback and EmitAOF for data type persistence
- [../commands/registration.md](../commands/registration.md) - Command flags that affect replication
- [../lifecycle/module-loading.md](../lifecycle/module-loading.md) - Module lifecycle and context types
