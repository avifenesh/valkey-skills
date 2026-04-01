# Key Expiration

Use when understanding how Valkey expires keys (and hash fields), both lazily on access and proactively via the active expiration cycle.

Source: `src/expire.c` (~500 lines for active expiry), `src/db.c` (~300 lines for lazy expiry and expire management)

## Contents

- Two Expiration Strategies (line 20)
- Lazy Expiration: expireIfNeeded (line 29)
- Active Expiration: activeExpireCycle (line 70)
- Hash Field Expiration (Valkey-Specific) (line 166)
- Expire Management Functions (line 193)
- EXPIRE Command Family (line 219)
- Writable Replica Key Expiration (line 238)
- See Also (line 254)

---

## Two Expiration Strategies

Valkey uses two complementary strategies to ensure expired keys are removed:

1. **Lazy expiration** - check on every key access; if expired, delete before returning
2. **Active expiration** - periodic background sampling of keys with TTLs

Neither alone is sufficient. Lazy expiry misses keys that are never accessed again. Active expiry runs on a CPU budget and cannot guarantee immediate removal of all expired keys.

## Lazy Expiration: expireIfNeeded

```c
static keyStatus expireIfNeeded(serverDb *db, robj *key, robj *val, int flags);
```

Called from `lookupKey()` on every key access. Returns one of:

- `KEY_VALID` - key is not expired (or expiry is disabled/ignored)
- `KEY_EXPIRED` - key is logically expired but NOT deleted (replica or import mode)
- `KEY_DELETED` - key was expired and deleted

The decision flow:

1. If `server.lazy_expire_disabled`, return `KEY_VALID` immediately
2. Check if the key's TTL has passed via `objectIsExpired(val)` or `keyIsExpiredWithDictIndex()`
3. Call `getExpirationPolicyWithFlags()` to determine what action to take:

```c
expirationPolicy getExpirationPolicyWithFlags(int flags);
```

Returns one of:
- `POLICY_IGNORE_EXPIRE` - during loading, or when processing commands from primary/import source
- `POLICY_KEEP_EXPIRED` - on read-only replicas, in import mode, when `EXPIRE_AVOID_DELETE_EXPIRED` is set, or when expire action is paused
- `POLICY_DELETE_EXPIRED` - on primaries in normal operation

When the policy is `POLICY_DELETE_EXPIRED`, the key is removed via `deleteExpiredKeyAndPropagateWithDictIndex()`:

```c
void deleteExpiredKeyAndPropagateWithDictIndex(serverDb *db, robj *keyobj, int dict_index);
```

This function:
1. Deletes the key (sync or async per `lazyfree-lazy-expire` config)
2. Records latency
3. Fires `expired` keyspace notification
4. Signals modified key
5. Propagates a DEL/UNLINK to replicas and AOF
6. Increments `server.stat_expiredkeys`

## Active Expiration: activeExpireCycle

```c
ustime_t activeExpireCycle(int type);
```

Called from two places:
- `serverCron()` at `server.hz` frequency (default 10 Hz) with `ACTIVE_EXPIRE_CYCLE_SLOW`
- `beforeSleep()` on every event loop iteration with `ACTIVE_EXPIRE_CYCLE_FAST`

### Constants

```c
#define ACTIVE_EXPIRE_CYCLE_KEYS_PER_LOOP 20    /* Keys sampled per DB per loop */
#define ACTIVE_EXPIRE_CYCLE_FAST_DURATION 1000  /* Fast cycle budget: 1000 us */
#define ACTIVE_EXPIRE_CYCLE_SLOW_TIME_PERC 25   /* Slow cycle: max 25% of 1/hz period */
#define ACTIVE_EXPIRE_CYCLE_ACCEPTABLE_STALE 10 /* Stop if <10% of sampled keys expired */
```

### Effort Scaling

The `active-expire-effort` config (1-10, default 1) adjusts all parameters:

- `keys_per_loop = 20 + 20/4 * effort` (20 to 65)
- `acceptable_stale = 10 - effort` (10% down to 1%)
- Fast cycle duration: `1000 + 1000/4 * effort` us (1ms to 3.25ms)
- Slow cycle CPU budget: `(25 + 2*effort)%` of the hz period

### Two Job Types

`activeExpireCycle()` handles two independent expiry mechanisms:

1. **KEYS** - standard key-level TTL via `db->expires`
2. **FIELDS** - hash field-level TTL via `db->keys_with_volatile_items`

These alternate priority across event loop cycles to prevent starvation:

```c
if (expireCycleStartWithFields) {
    elapsed += activeExpireCycleJob(FIELDS, type, timelimit_us - elapsed);
    elapsed += activeExpireCycleJob(KEYS, type, timelimit_us - elapsed);
} else {
    elapsed += activeExpireCycleJob(KEYS, type, timelimit_us - elapsed);
    elapsed += activeExpireCycleJob(FIELDS, type, timelimit_us - elapsed);
}
expireCycleStartWithFields = !expireCycleStartWithFields;
```

### The Core Loop: activeExpireCycleJob

```c
static ustime_t activeExpireCycleJob(enum activeExpiryType jobType, int cycleType, ustime_t timelimit_us);
```

Maintains persistent state across calls via a static `expireState` per job type:

```c
typedef struct {
    unsigned int current_db; /* Next DB to test */
    bool timelimit_exit;     /* Time limit hit in previous call? */
} expireState;
```

Algorithm per database:

1. Sample `keys_per_loop` keys from the appropriate kvstore using `kvstoreScan()`
2. For each sampled key/field, check if expired and delete if so
3. Track the ratio of expired-to-sampled keys
4. **Repeat** if the expired ratio exceeds `config_cycle_acceptable_stale` percent
5. Stop if: all DBs scanned, time limit exceeded, or scan cursor wraps to 0

The scan callbacks:

- `expireScanCallback()` - for KEYS: tries `activeExpireCycleTryExpire()` on each entry, tracks TTL stats
- `fieldExpireScanCallback()` - for FIELDS: calls `dbReclaimExpiredFields()` per hash key

### Average TTL Tracking

The active expire cycle computes a running average TTL per database:

```c
db->expiry[jobType].avg_ttl = avg_ttl + (db->expiry[jobType].avg_ttl - avg_ttl) * avg_ttl_factor[n-1];
```

Uses precomputed `pow(0.98, n)` factors for efficient exponential moving average. This stat is reported in the INFO command.

### Fast vs Slow Cycle

| Property | Fast | Slow |
|----------|------|------|
| Trigger | beforeSleep() | serverCron() |
| Time budget | ~1-3.25ms | 25-43% of 1/hz period |
| Skips if | Previous slow cycle finished cleanly AND stale% is low | Never |
| Cooldown | Won't repeat for 2x its duration | None |
| Time check frequency | Every 16 iterations (KEYS) or every iteration (FIELDS) | Same |

## Hash Field Expiration (Valkey-Specific)

Valkey extends key-level TTLs with per-field TTLs on hash objects. This is tracked via:

- `db->keys_with_volatile_items` kvstore - tracks which hash keys have at least one field with a TTL
- `hashTypeHasVolatileFields(o)` - checks if a hash object has volatile fields

### Active Field Expiration

```c
size_t dbReclaimExpiredFields(robj *o, serverDb *db, mstime_t now, unsigned long max_entries, int didx);
```

Called from `fieldExpireScanCallback()` during the active expire cycle. Processes in batches of `EXPIRE_BULK_LIMIT` to avoid large stack allocations:

1. Calls `hashTypeDeleteExpiredFields()` to remove expired fields
2. If no more volatile fields remain, untracks the key from `keys_with_volatile_items`
3. If the hash is now empty, deletes the key entirely
4. Propagates `HDEL` commands and fires `hexpired` keyspace notifications
5. If key was deleted, propagates DEL and fires `del` notification

### Tracking Lifecycle

- `dbTrackKeyWithVolatileItems(db, o)` - called when adding/overwriting a hash that has volatile fields
- `dbUntrackKeyWithVolatileItems(db, o)` - called when removing a hash or when its last volatile field expires
- `dbUpdateObjectWithVolatileItemsTracking(db, o)` - re-evaluates whether a hash should be tracked

## Expire Management Functions

### Setting Expiry

```c
robj *setExpire(client *c, serverDb *db, robj *key, long long when);
```

Sets the absolute expiry time in milliseconds. May reallocate the value object (returns the new pointer). Adds the key to `db->expires` if it was not already there. On writable replicas, also calls `rememberReplicaKeyWithExpire()`.

### Removing Expiry

```c
int removeExpire(serverDb *db, robj *key);
```

Removes the key from `db->expires` and sets the object's expire to -1. Returns 1 if an expire was removed, 0 if the key had no expire.

### Querying Expiry

```c
long long getExpire(serverDb *db, robj *key);
```

Returns the absolute expire time in milliseconds, or -1 if no expire is set.

## EXPIRE Command Family

```c
void expireGenericCommand(client *c, mstime_t basetime, int unit);
```

Shared implementation for EXPIRE, PEXPIRE, EXPIREAT, PEXPIREAT. The `basetime` is `commandTimeSnapshot()` for relative commands and 0 for absolute variants.

Supports flags (parsed by `parseExtendedExpireArgumentsOrReply()`):

| Flag | Behavior |
|------|----------|
| `NX` | Set expiry only when key has no expiry |
| `XX` | Set expiry only when key already has an expiry |
| `GT` | Set expiry only when new expiry is greater than current |
| `LT` | Set expiry only when new expiry is less than current |

If the computed expiry is already in the past, the key is deleted immediately (via `deleteExpiredKeyFromOverwriteAndPropagate`). Otherwise, `setExpire()` is called. All expire commands are rewritten to `PEXPIREAT` for propagation to replicas and AOF.

## Writable Replica Key Expiration

Replicas normally do not expire keys - they wait for DEL from the primary. Exception: keys created directly on a writable replica.

```c
dict *replicaKeysWithExpire;  /* key name -> bitmap of DB IDs where key exists */
```

- `rememberReplicaKeyWithExpire(db, key)` - tracks the key; bitmap allows tracking across up to 64 databases
- `expireReplicaKeys()` - called periodically; samples random keys from the dict, tries to expire them
- `flushReplicaKeysWithExpireList()` - clears all tracking on FLUSHALL

The `expireReplicaKeys()` function stops after accumulating more than 3 unexpired keys or after 1ms, whichever comes first. This is a best-effort mechanism for the use case of using writable replicas as temporary compute caches.

---
