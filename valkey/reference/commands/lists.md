# List Commands

Use when you need ordered sequences - task queues, event logs, activity feeds, message buffers, or stacks. Lists maintain insertion order, support push/pop from both ends, and offer blocking variants for consumer patterns.

---

## Push Operations

### LPUSH

```
LPUSH key element [element ...]
```

Inserts one or more elements at the head (left) of the list. Creates the key if it does not exist. When multiple elements are given, they are inserted left to right, so the last element ends up at the head. Returns the list length after the operation.

**Complexity**: O(N) where N is the number of elements inserted

```
LPUSH queue "first"                -- 1
LPUSH queue "second" "third"       -- 3
LRANGE queue 0 -1                  -- "third", "second", "first"
```

### RPUSH

```
RPUSH key element [element ...]
```

Inserts one or more elements at the tail (right) of the list. Creates the key if it does not exist. Returns the list length.

**Complexity**: O(N)

```
RPUSH log "event1" "event2" "event3"    -- 3
LRANGE log 0 -1                          -- "event1", "event2", "event3"
```

---

## Pop Operations

### LPOP

```
LPOP key [count]
```

Removes and returns one or more elements from the head of the list. Without `count`, returns a single element. With `count`, returns up to `count` elements as an array. Returns nil if the list is empty or does not exist.

**Complexity**: O(N) where N is the number of elements returned

```
RPUSH tasks "a" "b" "c" "d"
LPOP tasks         -- "a"
LPOP tasks 2       -- 1) "b" 2) "c"
```

### RPOP

```
RPOP key [count]
```

Removes and returns one or more elements from the tail. Same semantics as LPOP but from the opposite end.

**Complexity**: O(N)

```
RPUSH stack "bottom" "middle" "top"
RPOP stack         -- "top"
RPOP stack 2       -- 1) "middle" 2) "bottom"
```

---

## Blocking Pop

### BLPOP

```
BLPOP key [key ...] timeout
```

Blocking variant of LPOP. Waits until an element is available in any of the specified lists or the timeout (in seconds) expires. Checks keys in order - pops from the first non-empty list. Returns a two-element array: the key name and the popped value. Returns nil on timeout. A timeout of 0 blocks indefinitely.

**Complexity**: O(N) where N is the number of keys

```
-- Consumer blocks until work is available (30-second timeout)
BLPOP queue:tasks 30
-- 1) "queue:tasks"
-- 2) '{"type":"email","to":"user@example.com"}'
```

### BRPOP

```
BRPOP key [key ...] timeout
```

Blocking variant of RPOP. Same semantics as BLPOP but pops from the tail.

**Complexity**: O(N)

---

## Range and Inspection

### LRANGE

```
LRANGE key start stop
```

Returns elements from index `start` to `stop` (inclusive, zero-based). Negative indices count from the end (-1 is the last element). Does not modify the list.

**Complexity**: O(S+N) where S is the offset and N is the number of elements returned

```
RPUSH colors "red" "green" "blue" "yellow"
LRANGE colors 0 -1      -- all elements
LRANGE colors 0 1       -- "red", "green"
LRANGE colors -2 -1     -- "blue", "yellow"
```

### LLEN

```
LLEN key
```

Returns the length of the list. Returns 0 if the key does not exist.

**Complexity**: O(1)

```
RPUSH items "a" "b" "c"
LLEN items    -- 3
```

### LINDEX

```
LINDEX key index
```

Returns the element at `index` in the list. Zero-based, negative indices count from the end. Returns nil if the index is out of range.

**Complexity**: O(N) where N is the number of elements to traverse

```
RPUSH letters "a" "b" "c" "d"
LINDEX letters 0      -- "a"
LINDEX letters -1     -- "d"
LINDEX letters 10     -- (nil)
```

### LPOS

```
LPOS key element [RANK rank] [COUNT count] [MAXLEN len]
```

Returns the index of matching elements. By default returns the first match. `RANK` specifies the nth match (negative for reverse), `COUNT` returns up to N matches, `MAXLEN` limits scanning.

**Complexity**: O(N)

```
RPUSH colors "red" "blue" "red" "green" "red"
LPOS colors "red"              -- 0
LPOS colors "red" RANK 2       -- 2 (second match)
LPOS colors "red" COUNT 0      -- [0, 2, 4] (all matches)
```

---

## Modification

### LSET

```
LSET key index element
```

Sets the list element at `index` to `element`. Errors if the index is out of range.

**Complexity**: O(N) for head/tail access, O(N) worst case

```
RPUSH tasks "old" "keep" "keep"
LSET tasks 0 "new"
LRANGE tasks 0 -1    -- "new", "keep", "keep"
```

### LINSERT

```
LINSERT key BEFORE | AFTER pivot element
```

Inserts `element` before or after the first occurrence of `pivot` in the list. Returns the list length after insertion, or -1 if `pivot` was not found.

**Complexity**: O(N) where N is the number of elements to traverse

```
RPUSH tasks "task1" "task3"
LINSERT tasks BEFORE "task3" "task2"
LRANGE tasks 0 -1    -- "task1", "task2", "task3"
```

### LREM

```
LREM key count element
```

Removes occurrences of `element` from the list. `count > 0` removes from head, `count < 0` removes from tail, `count = 0` removes all occurrences. Returns the number of elements removed.

**Complexity**: O(N+S) where N is list length and S is the number of removals

```
RPUSH nums "1" "2" "1" "3" "1"
LREM nums 2 "1"          -- 2 (removed first two "1"s from head)
LRANGE nums 0 -1         -- "2", "3", "1"
```

### LTRIM

```
LTRIM key start stop
```

Trims the list to the specified range, removing all elements outside it. Use to cap list size.

**Complexity**: O(N) where N is the number of elements removed

```
RPUSH log "e1" "e2" "e3" "e4" "e5"
LTRIM log -3 -1           -- keep last 3 elements
LRANGE log 0 -1           -- "e3", "e4", "e5"
```

Common pattern - capped log: `LPUSH log entry` then `LTRIM log 0 999` to keep at most 1000 entries.

---

## Move Operations

### LMOVE

```
LMOVE source destination LEFT | RIGHT LEFT | RIGHT
```

Atomically pops an element from `source` (left or right) and pushes it to `destination` (left or right). Returns the moved element. Returns nil if source is empty.

**Complexity**: O(1)

```
RPUSH queue:pending "task1" "task2"
LMOVE queue:pending queue:processing LEFT LEFT
-- "task1" (moved from pending to processing)
```

### BLMOVE

```
BLMOVE source destination LEFT | RIGHT LEFT | RIGHT timeout
```

Blocking variant of LMOVE. Waits for an element to be available in `source`. Timeout in seconds (0 for indefinite).

**Complexity**: O(1)

---

## Multi-Pop

### LMPOP

```
LMPOP numkeys key [key ...] LEFT | RIGHT [COUNT count]
```

Pops elements from the first non-empty list among the specified keys. Returns a two-element array: the key name and the list of popped elements. Available since 7.0.

**Complexity**: O(N+M) where N is the number of keys and M is the number of elements popped

```
RPUSH q1 "a" "b"
RPUSH q2 "c" "d"
LMPOP 2 q1 q2 LEFT COUNT 2
-- 1) "q1"
-- 2) 1) "a" 2) "b"
```

### BLMPOP

```
BLMPOP timeout numkeys key [key ...] LEFT | RIGHT [COUNT count]
```

Blocking variant of LMPOP. Waits until elements are available or timeout expires. Available since 7.0.

**Complexity**: O(N+M)

```
BLMPOP 30 2 queue:high queue:low LEFT COUNT 1
```

---

## Practical Patterns

**Simple task queue (FIFO)**:
```
-- Producer
RPUSH queue:tasks '{"type":"email","to":"user@example.com"}'

-- Consumer (blocking, 30s timeout)
BLPOP queue:tasks 30
```

**Reliable queue (process-or-return)**:
```
-- Move task to processing list atomically
BLMOVE queue:tasks queue:processing LEFT LEFT 30

-- After processing, remove from processing list
LREM queue:processing 1 task_data

-- If consumer crashes, items remain in queue:processing for recovery
```

**Capped event log**:
```
LPUSH events:user:1000 '{"action":"login","ts":1711670400}'
LTRIM events:user:1000 0 99    -- keep last 100 events
```

**Priority queue with multiple lists**:
```
-- Insert by priority
RPUSH queue:critical task1
RPUSH queue:normal task2

-- Consumer checks critical first
BLPOP queue:critical queue:normal 30
```

**Stack (LIFO)**:
```
LPUSH stack "item1"
LPUSH stack "item2"
LPOP stack    -- "item2" (last in, first out)
```

---

## See Also

- [Queue Patterns](../patterns/queues.md) - task queues using LPUSH/BRPOP and LMOVE
- [Performance Best Practices](../best-practices/performance.md) - pipelining for batch list operations
- [Anti-Patterns](../anti-patterns/quick-reference.md) - unbounded list growth, blocking commands on shared connections
