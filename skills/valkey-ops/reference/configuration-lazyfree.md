Use when tuning background deletion behavior, reducing latency spikes from

# Lazy Free Configuration
large key eviction/expiry, or understanding the difference between DEL and
UNLINK.

## Contents

- What It Is (line 19)
- Configuration (line 32)
- UNLINK vs DEL (line 74)
- FLUSHDB / FLUSHALL with ASYNC (line 92)
- Impact on Latency and Memory (line 108)
- Recommended Settings (line 141)
- See Also (line 157)

---

## What It Is

Lazy free (also called asynchronous free) offloads memory reclamation to
background threads (BIO threads) instead of blocking the main thread. When a
large key is deleted, expired, or evicted, the main thread unlinks the object
from the keyspace and queues the actual memory deallocation to a background
thread.

Without it, freeing a hash with millions of fields or a sorted set with millions of members causes latency spikes.

Implementation is in `src/lazyfree.c` and `src/bio.c`.

## Configuration

All five lazyfree parameters default to `yes` in current Valkey. Source-verified
from `src/config.c` (lines 3253-3257) - all have default value `1`:

| Parameter | Default | Description |
|-----------|---------|-------------|
| `lazyfree-lazy-eviction` | `yes` | When evicting keys due to maxmemory policy, free memory in background. |
| `lazyfree-lazy-expire` | `yes` | When keys expire (active or passive expiry), free memory in background. |
| `lazyfree-lazy-server-del` | `yes` | When the server implicitly deletes a key (e.g., RENAME target, SET replacing old value), free in background. |
| `lazyfree-lazy-user-del` | `yes` | Make DEL behave like UNLINK - user DEL commands free in background. |
| `lazyfree-lazy-user-flush` | `yes` | Make FLUSHDB/FLUSHALL behave as if ASYNC was specified. |

All parameters are runtime-modifiable via `CONFIG SET`.

### What Each Controls

**lazyfree-lazy-eviction**: Applies when maxmemory is reached and the eviction
policy removes keys. Without this, evicting a 10 million member sorted set
would block the main thread for hundreds of milliseconds. With it, the key is
unlinked instantly and memory freed in the background.

**lazyfree-lazy-expire**: Applies to both active expiry (the periodic
expiry cycle that proactively scans for expired keys) and passive expiry
(checking TTL when a key is accessed). Large expired keys are freed in the
background.

**lazyfree-lazy-server-del**: Covers implicit deletions by the server.
Examples: `RENAME key newkey` deletes `newkey` if it exists; `SET key value`
replaces the old value. These internal deletions happen in the background.

**lazyfree-lazy-user-del**: When set to `yes`, the `DEL` command behaves
identically to `UNLINK` - it unlinks the key and queues background freeing.
Transparent behavioral change with no API difference from the
client's perspective.

**lazyfree-lazy-user-flush**: When set to `yes`, `FLUSHDB` and `FLUSHALL`
behave as if the `ASYNC` flag was specified. The server swaps in a fresh
empty database and queues the old one for background freeing. This also
affects Lua script reset (source: `src/config.c` line 2673 - `evalReset` is
called with the lazyfree-lazy-user-flush flag).

## UNLINK vs DEL

| Command | Behavior | Blocking |
|---------|----------|----------|
| `DEL` (lazyfree-lazy-user-del = no) | Synchronous free. Blocks main thread. | Yes - proportional to key size. |
| `DEL` (lazyfree-lazy-user-del = yes) | Behaves like UNLINK. | No - only unlink is synchronous. |
| `UNLINK` | Always async. Unlinks key, queues background free. | No - O(1) for the unlink step. |

With the default `lazyfree-lazy-user-del yes`, there is no practical difference
between `DEL` and `UNLINK`. Use either interchangeably.

### When UNLINK Still Matters

Even with lazyfree-lazy-user-del set to `yes`, explicitly using `UNLINK` makes
your intent clear and protects against config changes. If someone later sets
`lazyfree-lazy-user-del no`, `UNLINK` calls remain non-blocking while `DEL`
calls would become blocking.

## FLUSHDB / FLUSHALL with ASYNC

```bash
# Explicit async flush (always background regardless of config)
valkey-cli FLUSHDB ASYNC

# With lazyfree-lazy-user-flush = yes, this is equivalent:
valkey-cli FLUSHDB

# Explicit sync flush (overrides lazyfree config)
valkey-cli FLUSHDB SYNC
```

The `ASYNC` and `SYNC` modifiers always override the lazyfree config setting
for that specific command invocation.

## Impact on Latency and Memory

### Latency

With all lazyfree options enabled (the defaults), the main thread cost of
deleting any key is O(1) regardless of key size - it just unlinks the pointer
and increments the lazyfree counter. The actual deallocation happens in
background threads.

### Memory

Background freeing means memory is not immediately reclaimed. There is a
window where:

1. The key is no longer accessible (unlinked from keyspace)
2. The memory is still allocated (pending background thread processing)

This is visible via `lazyfree_pending_objects` in `INFO stats`. Under normal
load this window is negligible. Under extreme deletion rates, pending objects
can accumulate temporarily.

```bash
# Monitor pending lazy frees
valkey-cli INFO stats | grep lazyfree
```

### Replication Impact

Lazy free operations replicate as their logical equivalent. When
`lazyfree-lazy-user-del yes` makes DEL behave like UNLINK, the replication
stream still sends `DEL`. Replicas apply their own lazyfree settings
independently.

## Recommended Settings

The defaults (all `yes`) are appropriate for virtually all production workloads.
There is no downside to background freeing in normal operation.

Only consider disabling lazyfree if:

- You need deterministic memory accounting (rare - embedded/IoT use cases)
- You are debugging memory issues and need synchronous deallocation
- You are running benchmarks where background thread CPU interference matters

```bash
# Verify all lazyfree settings (should all be "yes")
valkey-cli CONFIG GET lazyfree-*
```
