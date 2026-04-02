# Lua Scripting and Functions

Use when writing atomic multi-key operations, migrating EVAL scripts to FUNCTION LOAD, debugging script timeouts, or deciding whether a Lua script is still needed now that SET IFEQ and DELIFEQ exist.

## Contents

- EVAL vs FCALL: When to Use Each (line 13)
- Script Replication (line 38)
- Determinism Requirements (line 56)
- Read-Only Scripts: EVAL_RO and FCALL_RO (line 73)
- Script Timeout (line 87)
- Valkey Replacements for Common Lua Patterns (line 112)
- Library Registration with FUNCTION LOAD (line 122)
- Error Handling in Lua (line 147)
- Anti-Patterns (line 163)
- Practical Examples (line 177)

---

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
# Renamed from lua-time-limit in Valkey 8.0+
# Default: 5000 ms
CONFIG SET busy-script-time 5000
```

Both `busy-script-time` (Valkey) and `lua-time-limit` (Redis compat) are accepted. Use `busy-script-time` in new configs.

**When a script exceeds the timeout**:
1. Valkey enters BUSY state - all commands rejected except `SCRIPT KILL` and `SHUTDOWN NOSAVE`.
2. Clients receive: `BUSY Valkey is busy running a script`
3. `SCRIPT KILL` terminates the script only if it has not yet executed any writes. A script that has written cannot be killed (partial writes cannot be rolled back) - only `SHUTDOWN NOSAVE` can abort it.

**Script memory limit**:
```
lua-memory-limit 10mb    # Default: 10 MB per execution
```

Scripts that accumulate large intermediate tables or strings will hit this limit and be terminated.

**Prevention**: keep scripts short; never iterate large collections inside Lua - use SCAN-based iteration in application code instead.

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

```lua
-- Register a named library (once per deployment)
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

Libraries persist across restarts. EVALSHA cache does not. For production scripts that must survive restarts or redeploys, use `FUNCTION LOAD` over `SCRIPT LOAD`.

Library versioning convention: embed version in the name (`mylib_v2`) or use `FUNCTION LOAD REPLACE` to overwrite atomically.

---

## Error Handling in Lua

```lua
-- Raise an error (client sees error response)
return redis.error_reply("ERR something went wrong")

-- Return a status (client sees simple string, not error)
return redis.status_reply("OK")
```

`server.call()` raises on any Valkey error and aborts the script. Use `server.pcall()` to catch errors within the script:

```lua
local ok, err = server.pcall('get', KEYS[1])
if err then
  return redis.error_reply("ERR key has wrong type")
end
return ok
```

`redis.call` and `server.call` are identical. Prefer `server.call` in new code - it is the Valkey naming convention.

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
