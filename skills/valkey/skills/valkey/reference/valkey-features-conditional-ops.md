# Conditional Operations: SET IFEQ and DELIFEQ

Use when implementing compare-and-swap patterns, safe distributed lock release, or any scenario where you need to conditionally update or delete a key based on its current value.

## SET IFEQ - Conditional Update (Valkey 8.1+)

Atomically update a key's value only if the current value matches an expected value. Eliminates the GET-compare-SET round-trip previously requiring Lua scripts.

### Syntax

```
SET key new_value IFEQ expected_value [EX seconds | PX milliseconds | EXAT unix-time-seconds | PXAT unix-time-milliseconds | KEEPTTL] [GET]
```

### Behavior

- If the current value of `key` equals `expected_value`, the value is updated to `new_value` and the command returns `OK`
- If the current value does NOT match, the command returns `nil` and no change is made
- **If the key does not exist, the command returns `nil` and no change is made - IFEQ never creates a new key.** A CAS retry loop that only treats `nil` as "someone beat me" must also handle the "key was deleted" case (e.g. check `EXISTS` after, or create with a separate `SET ... NX` if missing).
- The comparison and update are atomic - no race condition window

### Return values with `GET`

The `GET` flag returns the old value **before** IFEQ is evaluated. So the reply is:

- Key exists + IFEQ matches → old value returned, new value stored
- Key exists + IFEQ mismatches → old value returned, key unchanged
- Key doesn't exist → `nil` returned, key not created

The caller cannot distinguish "matched and set" from "mismatched and not set" from the GET-reply alone; use the non-GET form if you need to know the outcome.

### Examples

```
# Basic conditional update
SET mykey "initial"
SET mykey "updated" IFEQ "initial"     # Returns OK (match, value updated)
SET mykey "again" IFEQ "initial"       # Returns nil (no match - value is "updated")

# With GET flag - returns old value regardless of IFEQ outcome;
# returns nil if the key did not exist (and IFEQ aborts the set in that case).
SET mykey "new_value" IFEQ "updated" GET    # Returns "updated", sets to "new_value"

# With TTL
SET mykey "refreshed" IFEQ "new_value" EX 3600    # Update and set 1-hour TTL
```

### Use Cases

**Compare-and-swap (CAS) pattern**: Multiple services updating a shared cached value without conflicts.

```
# Service A reads current value
current = GET config:feature_flags
# Service A updates only if no one else changed it
SET config:feature_flags new_flags IFEQ current
# If nil returned: someone else updated first, re-read and retry
```

**State machine transitions**: Ensure a state change only happens from the expected state.

```
SET order:5678:status "shipped" IFEQ "processing"    # Only if still processing
SET order:5678:status "delivered" IFEQ "shipped"      # Only if shipped
```

**Optimistic concurrency control**: Avoid Lua scripting overhead for simple compare-and-swap.

```
# Before Valkey 8.1 (required Lua)
EVAL "if server.call('get',KEYS[1]) == ARGV[1] then
  return server.call('set',KEYS[1],ARGV[2])
else return nil end" 1 mykey old_value new_value

# Valkey 8.1+ (native command)
SET mykey new_value IFEQ old_value
```

> Both `server.call` and `redis.call` are valid inside Valkey Lua scripts (Valkey registers both globals). Existing Redis scripts using `redis.call` run unchanged.

---

## DELIFEQ - Conditional Delete (Valkey 9.0+)

Atomically delete a key only if its current value matches. Replaces the Lua script required for safe distributed lock release.

### Syntax

```
DELIFEQ key expected_value
```

### Behavior

- Returns `1` if the key existed and its value matched (key deleted)
- Returns `0` if the key did not exist or the value did not match (no change)
- Atomic - no race condition between check and delete

### Examples

```
# Basic conditional delete
SET mylock "owner_abc123"
DELIFEQ mylock "owner_abc123"     # Returns 1 (deleted)
DELIFEQ mylock "wrong_owner"     # Returns 0 (not deleted - key already gone)
```

### Primary Use Case: Safe Lock Release

The primary use of DELIFEQ is safe lock release. Only release a lock you own - otherwise you release another process's lock.

```
# Acquire lock (SET NX with TTL)
SET lock:resource my_random_token NX PX 30000

# ... do work ...

# Release lock - only if we still own it
DELIFEQ lock:resource my_random_token
```

Before DELIFEQ, this required a Lua script:

```
# Pre-9.0 safe lock release (Lua script)
EVAL "if server.call('get',KEYS[1]) == ARGV[1] then
  return server.call('del',KEYS[1])
else return 0 end" 1 lock:resource my_random_token

# Valkey 9.0+ (native command)
DELIFEQ lock:resource my_random_token
```

Simpler, faster (no Lua overhead), and easier to audit.

---

## Important Notes

- **Value comparison is exact byte-level matching** - "100" does not match "100 " (trailing space)
- **Both commands work on string-type keys only** - if the key holds a non-string value (e.g., a set or hash), both IFEQ and DELIFEQ return a WRONGTYPE error
- **IFEQ is exclusive with NX and XX** - you cannot combine IFEQ with NX or XX in the same SET command
- **Always use random tokens for locks** - predictable values defeat the purpose of conditional delete

### DELIFEQ as the Canonical Redlock Unlock

DELIFEQ is the native replacement for the canonical Redlock unlock pattern. Before 9.0, unlocking required a Lua script on each of N instances. DELIFEQ replaces the script with a single atomic command:

```
# Release Redlock on all 5 instances
DELIFEQ lock:resource <random_value>    # Instance 1
DELIFEQ lock:resource <random_value>    # Instance 2
DELIFEQ lock:resource <random_value>    # Instance 3
DELIFEQ lock:resource <random_value>    # Instance 4
DELIFEQ lock:resource <random_value>    # Instance 5
```

A `0` reply from any of these is **not a failure**. It means either the lock already expired on that node or a different owner now holds it - in Redlock semantics, that's still a successful release from this client's perspective. Continue issuing DELIFEQ on the remaining instances; do not retry the 0-reply instance.

---

## Replication

Both IFEQ-SET and DELIFEQ are **rewritten to plain `SET` and `DEL`** on the replication stream and AOF. Replicas and AOF readers see only the concrete write or delete - the conditional is evaluated once on the primary and the result is propagated unconditionally. This means:

- Replicas stay deterministic even across reconnects; they don't re-run the comparison.
- An operator tailing the AOF for auditing will not see `DELIFEQ` or `SET ... IFEQ` - they'll see `DEL` / `SET`.
- `MONITOR` on the primary shows the original command; `MONITOR` on a replica shows the rewritten one.

---

## Migration from Lua Scripts

Replace existing Lua scripts with native commands:

| Pattern | Pre-8.1 (Lua) | Valkey 8.1+/9.0+ |
|---------|---------------|-------------------|
| Compare-and-swap | EVAL with GET + SET | `SET key val IFEQ old_val` |
| Safe lock release | EVAL with GET + DEL | `DELIFEQ key token` |

Benefits of native commands: lower latency (no Lua VM), simpler code, no script caching needed.

---

