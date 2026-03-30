# Transaction Commands

Use when you need to execute a batch of commands atomically without interleaving from other clients. Transactions guarantee that either all commands execute or none do (if aborted). For read-then-write logic, use WATCH for optimistic locking or Lua scripts for complex conditions.

---

## Core Commands

### MULTI

```
MULTI
```

Marks the start of a transaction. After MULTI, all subsequent commands are queued (not executed) until EXEC is called. Each queued command returns QUEUED as acknowledgment.

```
MULTI
-- OK
SET user:1000:name "Alice"
-- QUEUED
SET user:1000:email "alice@example.com"
-- QUEUED
INCR user:1000:login_count
-- QUEUED
```

### EXEC

```
EXEC
```

Executes all queued commands atomically. Returns an array of results, one per command in queue order. No other client command runs between the commands in the transaction.

Returns nil if the transaction was aborted (by DISCARD or a WATCH violation).

```
EXEC
-- 1) OK
-- 2) OK
-- 3) (integer) 1
```

### DISCARD

```
DISCARD
```

Aborts the transaction. All queued commands are discarded and the connection returns to normal mode.

```
MULTI
SET key1 "value1"
-- QUEUED
DISCARD
-- OK (transaction cancelled, SET was never executed)
```

---

## Optimistic Locking

### WATCH

```
WATCH key [key ...]
```

Marks keys for monitoring before a transaction. If any watched key is modified by another client between WATCH and EXEC, the transaction is aborted - EXEC returns nil. This provides optimistic locking (check-and-set).

WATCH must be called before MULTI.

```
WATCH account:1000:balance
-- OK
```

### UNWATCH

```
UNWATCH
```

Cancels all watched keys for the current connection. Called automatically when EXEC or DISCARD is executed.

```
UNWATCH
-- OK
```

---

## Transaction Behavior

**Atomicity**: Commands in a transaction execute sequentially without interleaving. No other client's command runs between any two commands in the transaction.

**No rollback**: If a command inside a transaction fails (e.g., wrong type), other commands still execute. Valkey does not roll back on command errors. Only EXEC-time failures (watch violations, out-of-memory) abort the entire transaction.

**Queueing errors**: If a command has a syntax error when queued (e.g., wrong number of arguments), EXEC returns an error and the entire transaction is discarded.

```
MULTI
SET key1 "value1"
-- QUEUED
INCR key1           -- will fail at execution (key1 is not an integer)
-- QUEUED
SET key2 "value2"
-- QUEUED
EXEC
-- 1) OK
-- 2) (error) ERR value is not an integer or out of range
-- 3) OK
-- key1 = "value1", key2 = "value2" (both SETs succeeded despite INCR error)
```

---

## Optimistic Locking Pattern

The WATCH/MULTI/EXEC pattern implements check-and-set (CAS) without blocking:

```
-- Debit account only if sufficient balance
WATCH account:1000:balance
balance = GET account:1000:balance    -- "500"

if balance >= 100:
    MULTI
    DECRBY account:1000:balance 100
    INCRBY account:2000:balance 100
    EXEC
    -- If another client modified account:1000:balance after WATCH,
    -- EXEC returns nil and no commands execute.
    -- Retry the entire block.
else:
    UNWATCH
    -- Insufficient funds
```

**Retry loop**: When EXEC returns nil (watch violation), re-read the values and retry. This is safe because no partial writes occurred.

```
-- Pseudocode
while true:
    WATCH mykey
    value = GET mykey
    new_value = compute(value)
    MULTI
    SET mykey new_value
    result = EXEC
    if result is not nil:
        break    -- success
    -- else: retry (another client modified mykey)
```

---

## Transactions vs Lua Scripts

| Feature | MULTI/EXEC | Lua Scripts / Functions |
|---------|-----------|----------------------|
| Atomicity | Yes | Yes |
| Read-then-write | Only with WATCH (optimistic) | Yes (within script) |
| Conditional logic | No | Yes |
| Retry on conflict | Application-side retry loop | No conflict (blocks server) |
| Network overhead | One round-trip per command + EXEC | Single round-trip |
| Performance | Multiple round-trips for WATCH pattern | Single round-trip |

**Use MULTI/EXEC** when:
- You need to batch independent writes (no reads between them)
- Low contention on watched keys (retries are rare)
- Simple batching without conditional logic

**Use Lua scripts** when:
- You need to read a value, decide, then write - all atomically
- High contention would cause frequent WATCH retries
- You need conditional logic or computation server-side

---

## Cluster Considerations

In cluster mode, all keys in a transaction (including WATCHed keys) must belong to the same hash slot. Use hash tags to co-locate related keys:

```
WATCH {account:1000}:balance
GET {account:1000}:balance
MULTI
DECRBY {account:1000}:balance 100
RPUSH {account:1000}:transactions '{"type":"debit","amount":100}'
EXEC
```

---

## Practical Patterns

**Atomic batch write**:
```
MULTI
HSET user:1000 name "Alice" email "alice@example.com"
SADD users:active "user:1000"
LPUSH events:user:1000 '{"action":"profile_updated"}'
EXEC
```

**Inventory reservation (optimistic lock)**:
```
WATCH product:42:stock
stock = GET product:42:stock
if stock > 0:
    MULTI
    DECR product:42:stock
    RPUSH orders:pending '{"product":42,"user":1000}'
    EXEC
    -- nil means someone else took the last item, retry
```

**Swap two values atomically**:
```
WATCH key1 key2
val1 = GET key1
val2 = GET key2
MULTI
SET key1 val2
SET key2 val1
EXEC
```

**Pipeline-friendly batch** (when you just need atomicity, no conditions):
```
MULTI
SET counter:page_views 0
SET counter:api_calls 0
SET counter:errors 0
EXEC
-- All three keys reset atomically
```

---

## See Also

- [Scripting and Functions](scripting.md) - Lua scripts for read-then-write atomic operations
- [Conditional Operations](../valkey-features/conditional-ops.md) - SET IFEQ replaces WATCH+MULTI for simple CAS
- [Lock Patterns](../patterns/locks.md) - optimistic locking with WATCH
- [Cluster Best Practices](../best-practices/cluster.md) - hash tags for co-locating keys in transactions
- [Performance Best Practices](../best-practices/performance.md) - pipelining MULTI/EXEC for network efficiency
- [Anti-Patterns](../anti-patterns/quick-reference.md) - WATCH+MULTI for complex logic
