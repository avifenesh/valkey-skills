# Scripting and Functions

Use when you need atomic read-then-write operations, complex conditional logic, or server-side computation that cannot be expressed with single commands or MULTI/EXEC. Lua scripting and Functions both execute atomically on the server - no other command runs during execution.

---

## EVAL - Inline Lua Scripts

### EVAL

```
EVAL script numkeys key [key ...] arg [arg ...]
```

Executes a Lua script on the server. `numkeys` declares how many arguments are keys (accessed via `KEYS[n]`), the rest are values (accessed via `ARGV[n]`). The script runs atomically.

**Complexity**: Depends on the script

```
-- Atomic compare-and-delete (pre-Valkey 9.0 lock release)
EVAL "if server.call('get',KEYS[1]) == ARGV[1] then return server.call('del',KEYS[1]) else return 0 end" 1 lock:resource "owner_abc"

-- Conditional increment
EVAL "local val = tonumber(server.call('get',KEYS[1]) or '0') if val < tonumber(ARGV[1]) then return server.call('incr',KEYS[1]) else return val end" 1 counter 100

-- Multi-key atomic operation
EVAL "server.call('set',KEYS[1],ARGV[1]) server.call('set',KEYS[2],ARGV[2]) return 'OK'" 2 key1 key2 val1 val2
```

**Key rules**:
- Always declare keys via `numkeys` and access them with `KEYS[n]` - never hardcode key names. This is required for cluster compatibility.
- Use `server.call()` to execute Valkey commands inside the script. Use `server.pcall()` for error-tolerant calls.
- Lua arrays are 1-indexed: `KEYS[1]`, `ARGV[1]`.

### EVALSHA

```
EVALSHA sha1 numkeys key [key ...] arg [arg ...]
```

Executes a cached script by its SHA1 hash. If the script is not cached, returns a NOSCRIPT error - load it first with SCRIPT LOAD or fall back to EVAL.

**Complexity**: Same as the script

```
-- Load script, get SHA1
SCRIPT LOAD "return server.call('get',KEYS[1])"
-- "e0e1f9fabfc9d4800c877a703b823ac0578ff831"

-- Execute by hash (faster, no script transfer)
EVALSHA "e0e1f9fabfc9d4800c877a703b823ac0578ff831" 1 mykey
```

### EVAL_RO / EVALSHA_RO

```
EVAL_RO script numkeys key [key ...] arg [arg ...]
EVALSHA_RO sha1 numkeys key [key ...] arg [arg ...]
```

Read-only variants that reject write commands inside the script. Can be routed to replicas in cluster mode for read scaling. Available since 7.0.

```
-- Read-only script safe for replicas
EVAL_RO "return server.call('get',KEYS[1])" 1 mykey
```

---

## SCRIPT Management

### SCRIPT LOAD

```
SCRIPT LOAD script
```

Loads a script into the script cache without executing it. Returns the SHA1 hash. The script stays cached until SCRIPT FLUSH or server restart.

```
SCRIPT LOAD "return server.call('get',KEYS[1])"
-- "e0e1f9fabfc9d4800c877a703b823ac0578ff831"
```

### SCRIPT EXISTS

```
SCRIPT EXISTS sha1 [sha1 ...]
```

Checks whether scripts exist in the cache. Returns an array of 0/1 values.

```
SCRIPT EXISTS "e0e1f9fabfc9d4800c877a703b823ac0578ff831" "0000000000000000000000000000000000000000"
-- 1) 1
-- 2) 0
```

### SCRIPT KILL

```
SCRIPT KILL
```

Aborts the currently running read-only Lua script. Returns an error if the running script has already performed write operations - in that case, use `SHUTDOWN NOSAVE` as a last resort.

**Complexity**: O(1)

### SCRIPT FLUSH

```
SCRIPT FLUSH [ASYNC | SYNC]
```

Removes all scripts from the cache.

---

## Functions (Persistent Scripting)

Functions are persistent Lua libraries that survive restarts and are replicated to replicas. They replace volatile EVAL scripts for production use. Available since 7.0.

### FUNCTION LOAD

```
FUNCTION LOAD [REPLACE] function-code
```

Loads a function library. The code must declare the library name and register functions using the Valkey Functions API. Use REPLACE to overwrite an existing library.

```
FUNCTION LOAD "#!lua name=mylib\nserver.register_function('myfunc', function(keys, args) return server.call('get', keys[1]) end)"

-- With REPLACE to update
FUNCTION LOAD REPLACE "#!lua name=mylib\nserver.register_function('myfunc', function(keys, args) return server.call('set', keys[1], args[1]) end)"
```

**Library format**: The code starts with a shebang line `#!lua name=<library_name>` followed by function registrations.

### FCALL

```
FCALL function numkeys key [key ...] arg [arg ...]
```

Calls a loaded function by name. Same argument convention as EVAL - numkeys declares key arguments, the rest are values.

**Complexity**: Depends on the function

```
FCALL myfunc 1 mykey
```

### FCALL_RO

```
FCALL_RO function numkeys key [key ...] arg [arg ...]
```

Read-only variant of FCALL. Rejects write commands, can be routed to replicas.

### FUNCTION LIST

```
FUNCTION LIST [LIBRARYNAME pattern] [WITHCODE]
```

Lists loaded function libraries. LIBRARYNAME filters by pattern. WITHCODE includes the source code.

```
FUNCTION LIST
-- Returns library names, engines, and function details

FUNCTION LIST LIBRARYNAME "mylib" WITHCODE
```

### FUNCTION DELETE

```
FUNCTION DELETE library-name
```

Deletes a function library and all its functions.

```
FUNCTION DELETE mylib
```

### FUNCTION DUMP / RESTORE

```
FUNCTION DUMP
FUNCTION RESTORE serialized-value [FLUSH | APPEND | REPLACE]
```

DUMP serializes all function libraries. RESTORE loads them on another server. Use for migration.

```
-- On source server
payload = FUNCTION DUMP

-- On target server
FUNCTION RESTORE payload REPLACE
```

### FUNCTION KILL

```
FUNCTION KILL
```

Aborts the currently running read-only function. Returns an error if the running function has already performed write operations.

**Complexity**: O(1)

### FUNCTION STATS

```
FUNCTION STATS
```

Returns information about the currently running function (if any) and available engines.

### FUNCTION FLUSH

```
FUNCTION FLUSH [ASYNC | SYNC]
```

Deletes all function libraries.

---

## Lua Scripting Basics

**Data type mapping**:

| Lua type | Valkey response |
|----------|----------------|
| number (integer) | Integer reply |
| string | Bulk string reply |
| table (array) | Array reply |
| boolean true | Integer 1 |
| boolean false | Nil reply |
| nil | Nil reply |

**Calling Valkey commands**:
```lua
-- Raises error on failure
local value = server.call('GET', KEYS[1])

-- Returns error as Lua table on failure (non-throwing)
local result = server.pcall('GET', KEYS[1])
```

**Common patterns in Lua**:
```lua
-- Rate limiter
local current = tonumber(server.call('GET', KEYS[1]) or '0')
if current >= tonumber(ARGV[1]) then
    return 0
end
server.call('INCR', KEYS[1])
if current == 0 then
    server.call('EXPIRE', KEYS[1], ARGV[2])
end
return 1
```

```lua
-- Atomic hash update with conditional logic
local old = server.call('HGET', KEYS[1], ARGV[1])
if old == false then
    server.call('HSET', KEYS[1], ARGV[1], ARGV[2])
    return 1
end
return 0
```

---

## Functions vs EVAL Comparison

| Feature | EVAL / EVALSHA | FUNCTION LOAD / FCALL |
|---------|---------------|----------------------|
| Persistence | Volatile (cache only) | Persistent (survives restart) |
| Replication | Script re-executed on replicas | Library replicated with data |
| Management | SHA1-based, no naming | Named libraries and functions |
| Loading | Implicit (EVAL) or explicit (SCRIPT LOAD) | Explicit FUNCTION LOAD required |
| Versioning | None | REPLACE for updates |
| Cluster | Must exist on all nodes | Automatically propagated |
| Read-only routing | EVALSHA_RO | FCALL_RO |
| Recommended for | Ad-hoc scripts, development | Production workloads |

**Migration path**: Convert EVAL scripts to Functions for production:
1. Wrap your script in a library with `#!lua name=...`
2. Register functions with `server.register_function()`
3. Load with `FUNCTION LOAD`
4. Call with `FCALL` instead of `EVAL`

---

## Important Constraints

**Blocking**: Scripts block the entire server during execution. Keep scripts fast and avoid loops over large datasets.

**Timeout**: Default script timeout is 5 seconds (`busy-reply-threshold`). After the timeout, clients receive BUSY errors but the script continues. Use SCRIPT KILL to abort a read-only script, or SHUTDOWN NOSAVE as a last resort for write scripts.

**Replication**: Valkey uses effects replication by default (each write command within a script is replicated individually). This means non-deterministic commands like `TIME` and `RANDOMKEY` are safe to use in scripts - the actual effects are replicated, not the script itself. The older `lua-replicate-commands` config is deprecated and ignored. Use the read-only variants (EVAL_RO, FCALL_RO) when your script performs no writes.

**Cluster mode**: All keys accessed by a script must hash to the same slot. Use hash tags `{tag}` to co-locate keys.

---

## Practical Patterns

**Distributed lock release (safe)**:
```
EVAL "if server.call('get',KEYS[1]) == ARGV[1] then return server.call('del',KEYS[1]) else return 0 end" 1 lock:resource owner_id
```

Note: On Valkey 9.0+, prefer `DELIFEQ lock:resource owner_id` which does this natively.

**Token bucket rate limiter**:
```
EVAL "local tokens = tonumber(server.call('get',KEYS[1]) or ARGV[1]) local last = tonumber(server.call('get',KEYS[2]) or ARGV[3]) local now = tonumber(ARGV[3]) local rate = tonumber(ARGV[2]) tokens = math.min(tonumber(ARGV[1]), tokens + (now - last) * rate) if tokens >= 1 then tokens = tokens - 1 server.call('set',KEYS[1],tokens) server.call('set',KEYS[2],now) return 1 else server.call('set',KEYS[1],tokens) server.call('set',KEYS[2],now) return 0 end" 2 bucket:tokens bucket:last 10 1 current_timestamp
```

**Atomic transfer between accounts**:
```lua
-- As a Function library
#!lua name=banking
server.register_function('transfer', function(keys, args)
    local from_balance = tonumber(server.call('HGET', keys[1], 'balance'))
    local amount = tonumber(args[1])
    if from_balance >= amount then
        server.call('HINCRBY', keys[1], 'balance', -amount)
        server.call('HINCRBY', keys[2], 'balance', amount)
        return 1
    end
    return 0
end)
```

---

## See Also

- [Transaction Commands](transactions.md) - MULTI/EXEC vs Lua scripts comparison
- [Conditional Operations](../valkey-features/conditional-ops.md) - SET IFEQ and DELIFEQ replace common Lua patterns
- [Lock Patterns](../patterns/locks.md) - safe lock release with Lua or DELIFEQ
- [Rate Limiting Patterns](../patterns/rate-limiting.md) - token bucket Lua script
- [Cluster Best Practices](../best-practices/cluster.md) - hash tags for co-locating keys in scripts
- [Performance Best Practices](../best-practices/performance.md) - EVALSHA to avoid script retransmission
- [Anti-Patterns](../anti-patterns/quick-reference.md) - Lua scripts with unbounded loops
