# Lua Scripting and Functions

Use when writing atomic multi-key operations, migrating EVAL scripts to FUNCTION LOAD, debugging script timeouts, or deciding whether a Lua script is still needed now that SET IFEQ and DELIFEQ exist.

## EVAL vs FCALL: When to Use Each

- **EVAL** - ad-hoc scripts sent inline with each call. Simple, no setup. Cached by SHA1 after the first call via `EVALSHA`.
- **FCALL** - named functions registered with `FUNCTION LOAD`. Stored server-side by name. Persists across restarts (unlike EVALSHA cache).

```
# EVAL
EVAL "return server.call('set', KEYS[1], ARGV[1])" 1 mykey myvalue

# FCALL (after FUNCTION LOAD)
FCALL myset 1 mykey myvalue

# Load a script for reuse by SHA
SCRIPT LOAD "return server.call('get', KEYS[1])"
# Returns: "e0e1f9fabfa9d353a0970253f47af8b32f4504e7"
EVALSHA e0e1f9fabfa9d353a0970253f47af8b32f4504e7 1 mykey
```

Use EVAL for simple, app-specific scripts. Use FCALL for shared cross-service scripts, versioned deployments, or libraries with multiple related functions.

---

## Script Replication

Valkey uses **effects replication** by default: only the individual write commands executed by the script are replicated to replicas and AOF, not the script itself.

The legacy `redis.replicate_commands()` call is accepted for backward compatibility but is a no-op - effects replication is always on. Replicas do not re-execute the Lua code.

This means historical restrictions on scripts are largely relaxed, but writing deterministic scripts is still good practice for clarity and debuggability.

---

## Determinism Requirements

Under effects replication, non-determinism does not cause replica divergence directly. However, it creates unpredictable behavior in failure scenarios and makes scripts hard to reason about.

| Call to Avoid | Safe Alternative |
|---------------|-----------------|
| `server.call('TIME')` inside write scripts | Pass timestamp as `ARGV` from the client |
| `server.call('RANDOMKEY')` | Generate random value on the client, pass via `ARGV` |
| `math.random()` without fixed seed | Generate on client side |
| `server.call('SRANDMEMBER', ...)` in write scripts | Use `FCALL_RO` if read-only, or accept non-determinism explicitly |

---

## Read-Only Scripts: EVAL_RO and FCALL_RO

Read-only variants reject any write command inside the script.

```
EVAL_RO "return server.call('get', KEYS[1])" 1 mykey
FCALL_RO getprofile 1 user:1000:profile
```

Use when:
- **Directing reads to replicas** - `EVAL_RO`/`FCALL_RO` can run on replica nodes in cluster mode. Standard `EVAL`/`FCALL` require the primary.
- **Enforcing read-only intent** - prevents accidental writes in scripts that should only read.
- **ACL restrictions** - users with `@read` but not `@write` can run `EVAL_RO`.

In cluster mode, all keys in `KEYS[]` must still hash to the same slot.

---

## Script Timeout

```
# Canonical Valkey name; legacy alias `lua-time-limit` still accepted.
# Default: 5000 ms.
CONFIG SET busy-reply-threshold 5000
```

**When a script exceeds the threshold**:
1. Valkey enters BUSY state - most commands are rejected with a `-BUSY ...` error.
2. The exact `-BUSY` reply tells you which kill command applies:
   - Running EVAL / EVALSHA → *"You can only call SCRIPT KILL or SHUTDOWN NOSAVE"*
   - Running FCALL / FCALL_RO → *"You can only call FUNCTION KILL or SHUTDOWN NOSAVE"*
3. `SCRIPT KILL` / `FUNCTION KILL` only work **before the script has performed any write**. Once a write has been executed, the script cannot be killed - partial writes cannot be rolled back, so only `SHUTDOWN NOSAVE` can abort it.

**Prevention**: keep scripts short; never iterate large collections inside Lua - use SCAN-based iteration in application code instead. Lua memory is not separately capped - it counts against the same `maxmemory` budget as regular data, so an accumulating script can OOM the server.

---

## Valkey Replacements for Common Lua Patterns

Before writing a new script, check whether a native command already solves the problem:

| Pattern | Old Approach | Valkey Native |
|---------|-------------|---------------|
| Compare-and-swap | EVAL with GET + conditional SET | `SET key val IFEQ old_val` (8.1+) |
| Safe lock release | EVAL with GET + DEL | `DELIFEQ key token` (9.0+) |

Native commands are faster (no Lua VM overhead), simpler to audit, and work without hash tags in cluster mode. See the conditional-ops reference for full syntax.

---

## Library Registration with FUNCTION LOAD

Register a named library. The shebang `#!lua name=<libname>` is required on the first line of the function code:

```lua
FUNCTION LOAD "#!lua name=mylib\n
  local function cas(keys, args)
    local current = server.call('get', keys[1])
    if current == args[1] then
      return server.call('set', keys[1], args[2])
    end
    return false
  end
  server.register_function('cas', cas)"
```

`server.register_function` accepts two forms:

```lua
-- Positional: shown above. Works for basic registration.
server.register_function('cas', cas)

-- Named (table): required when setting flags or a description.
server.register_function{
  function_name = 'getprofile',
  callback      = getprofile,
  description   = 'Read-only user profile lookup',
  flags         = {'no-writes'}   -- marks the function as read-only (callable via FCALL_RO)
}
```

The `no-writes` flag is the one most often needed - without it you cannot expose a function through `FCALL_RO` even if it never writes.

```
-- Call from application code
FCALL cas 1 mykey expected_value new_value

-- Manage libraries
FUNCTION LIST
FUNCTION DELETE mylib
FUNCTION DUMP          -- backup
FUNCTION RESTORE <binary>

-- Overwrite in place (atomic)
FUNCTION LOAD REPLACE "#!lua name=mylib\n ..."
```

Libraries persist across restarts (they are included in RDB/AOF). EVALSHA cache does not - a restart means every `EVALSHA <sha>` will return `NOSCRIPT` until the script is loaded again. For production scripts that must survive restarts or redeploys, use `FUNCTION LOAD` over `SCRIPT LOAD`.

Library versioning convention: embed version in the name (`mylib_v2`) or use `FUNCTION LOAD REPLACE` to overwrite atomically.

---

## Error Handling in Lua

```lua
-- Raise an error (client sees error response)
return server.error_reply("ERR something went wrong")

-- Return a status (client sees simple string, not error)
return server.status_reply("OK")
```

`server.call()` raises on any Valkey error and aborts the script. Use `server.pcall()` to catch errors within the script.

**`server.pcall` return shape** - this trips people up. It is NOT Lua's native `pcall`. It returns **one** value:

- On success: the command result (string, number, array, etc.).
- On error: a Lua **table** with a single `err` field (not a `(status, value)` tuple).

Correct pattern:

```lua
local result = server.pcall('get', KEYS[1])
if type(result) == 'table' and result.err then
  -- Propagate the actual Valkey error message
  return server.error_reply(result.err)
end
return result
```

**Aliases**: `redis.call` / `redis.pcall` / `redis.error_reply` / `redis.status_reply` all work identically to the `server.*` versions - the `redis` global is an alias of `server` set up for pre-Valkey compatibility. Prefer `server.*` in new code; `redis.*` is fine in existing scripts.

---

## Anti-Patterns

**Non-deterministic writes**: Calling `TIME` or `RANDOMKEY` inside write scripts creates unclear behavior on replica failover. Pass these values from the client.

**Large return values**: Scripts aggregating thousands of elements cause high Lua VM serialization overhead and risk timeouts. Return partial results with cursor logic, or aggregate in application code.

**Cross-slot writes in cluster mode**: `EVAL`/`FCALL` require all `KEYS[]` in the same hash slot. Use hash tags `{tag}` to co-locate keys that a script must touch together.

**Business logic in scripts**: Lua runs on the main thread and blocks all other clients. Complex logic, heavy computation, and anything resembling a network call does not belong in scripts.

---

## Practical Examples

### Atomic CAS: Before and After IFEQ

Before Valkey 8.1 (Lua required):
```lua
local current = server.call('get', KEYS[1])
if current == ARGV[1] then
  return server.call('set', KEYS[1], ARGV[2])
end
return false
```

After Valkey 8.1 (native, no Lua needed):
```
SET mykey new_value IFEQ expected_value
```

### Sliding Window Rate Limiter

Still a good use case for Lua - multiple operations that must be atomic:

```lua
-- KEYS[1]: sorted set key, ARGV[1]: now_ms (from client!), ARGV[2]: window_ms, ARGV[3]: limit
local now = tonumber(ARGV[1])
local cutoff = now - tonumber(ARGV[2])
server.call('ZREMRANGEBYSCORE', KEYS[1], '-inf', cutoff)
local count = server.call('ZCARD', KEYS[1])
if count < tonumber(ARGV[3]) then
  server.call('ZADD', KEYS[1], now, now .. '-' .. math.random(1000000))
  server.call('PEXPIRE', KEYS[1], ARGV[2])
  return 1
end
return 0
```

The timestamp is passed as `ARGV[1]` from the client - never generated inside the script via `TIME` - keeping the script deterministic.

---
