# Keyspace Notifications

Use when working on event-driven features that react to key changes, or when debugging why notifications are or are not firing.

Source: `src/notify.c`

## Contents

- Overview (line 21)
- Configuration (line 25)
- Parsing Functions (line 57)
- Core Function (line 67)
- Debug Assertion (line 115)
- Callers (line 122)
- Subscribing to Notifications (line 136)
- Performance Notes (line 147)
- See Also (line 153)

---

## Overview

Keyspace notifications piggyback on the pub/sub subsystem. When a key is modified, Valkey publishes messages to special channels that encode the database ID, key name, and event type. The entire file is compact - roughly 160 lines including the license header.

## Configuration

Controlled by `server.notify_keyspace_events`, an integer bitmask set via the `notify-keyspace-events` config option.

### Event Type Flags (server.h)

```c
#define NOTIFY_KEYSPACE (1 << 0)   /* K - keyspace notifications */
#define NOTIFY_KEYEVENT (1 << 1)   /* E - keyevent notifications */
#define NOTIFY_GENERIC  (1 << 2)   /* g - generic commands (DEL, EXPIRE, RENAME, ...) */
#define NOTIFY_STRING   (1 << 3)   /* $ - string commands */
#define NOTIFY_LIST     (1 << 4)   /* l - list commands */
#define NOTIFY_SET      (1 << 5)   /* s - set commands */
#define NOTIFY_HASH     (1 << 6)   /* h - hash commands */
#define NOTIFY_ZSET     (1 << 7)   /* z - sorted set commands */
#define NOTIFY_EXPIRED  (1 << 8)   /* x - expired events */
#define NOTIFY_EVICTED  (1 << 9)   /* e - evicted events */
#define NOTIFY_STREAM   (1 << 10)  /* t - stream commands */
#define NOTIFY_KEY_MISS (1 << 11)  /* m - key miss events (excluded from NOTIFY_ALL) */
#define NOTIFY_LOADED   (1 << 12)  /* module only - key loaded from rdb */
#define NOTIFY_MODULE   (1 << 13)  /* d - module key space notification */
#define NOTIFY_NEW      (1 << 14)  /* n - new key notification */

#define NOTIFY_ALL (NOTIFY_GENERIC | NOTIFY_STRING | NOTIFY_LIST | NOTIFY_SET |
                    NOTIFY_HASH | NOTIFY_ZSET | NOTIFY_EXPIRED | NOTIFY_EVICTED |
                    NOTIFY_STREAM | NOTIFY_MODULE)
```

`NOTIFY_KEY_MISS` is intentionally excluded from `NOTIFY_ALL` - it must be enabled explicitly with `m`. `NOTIFY_NEW` (the `n` flag) is also excluded from `NOTIFY_ALL` and must be enabled explicitly.

To receive notifications, at least one of `K` (keyspace) or `E` (keyevent) must be set alongside the event type flags. Setting just `g` without `K` or `E` produces nothing.

## Parsing Functions

### keyspaceEventsStringToFlags(char *classes)

Converts a config string like `"KEg"` to a bitmask. Returns -1 on unrecognized characters.

### keyspaceEventsFlagsToString(int flags)

Reverse conversion - bitmask to sds string. Used for CONFIG GET output. If all data-type bits are set, emits `"A"` instead of individual flags.

## Core Function

### notifyKeyspaceEvent(int type, char *event, robj *key, int dbid)

```c
void notifyKeyspaceEvent(int type, char *event, robj *key, int dbid);
```

Parameters:
- `type` - one of the `NOTIFY_*` bitmask values indicating the event class
- `event` - C string naming the specific event (e.g. `"set"`, `"del"`, `"expired"`)
- `key` - the affected key as an robj
- `dbid` - database number where the key lives

Execution flow:

**Step 1 - Module notification (always runs):**
```c
moduleNotifyKeyspaceEvent(type, event, key, dbid);
```
This bypasses the `notify-keyspace-events` config entirely. Modules that registered for keyspace events via `ValkeyModule_SubscribeToKeyspaceEvents` always get notified. The module engine filters by event type internally.

After module notification, the client's `keyspace_notified` flag is set and deferred reply buffers are committed.

**Step 2 - Config check:**
```c
if (!(server.notify_keyspace_events & type)) return;
```
If the event type is not enabled in config, return immediately. No pub/sub messages are generated.

**Step 3 - Keyspace notification (if K flag set):**
Publishes to channel `__keyspace@<db>__:<key>` with the event name as the message.

```c
chan = "__keyspace@" + dbid + "__:" + key
pubsubPublishMessage(chan, event, 0);
```

**Step 4 - Keyevent notification (if E flag set):**
Publishes to channel `__keyevent@<db>__:<event>` with the key name as the message.

```c
chan = "__keyevent@" + dbid + "__:" + event
pubsubPublishMessage(chan, key, 0);
```

Both use `pubsubPublishMessage` with `sharded=0` - keyspace notifications always go through global pub/sub, never shard channels.

## Debug Assertion

The function includes a debug assertion that checks write commands on normal clients have set the `keyspace_notified` flag or have buffered replies committed. This catches cases where notifications might be delivered out of order relative to the command response. The assertion is skipped for:
- AOF replay clients (`c->id == UINT64_MAX`)
- Non-normal client types (replicas, pub/sub-only clients)
- Read-only commands

## Callers

`notifyKeyspaceEvent` is called throughout the codebase whenever a key is created, modified, deleted, expired, or evicted. Common call sites:

- `t_string.c` - SET, APPEND, INCR, etc. fire `NOTIFY_STRING`
- `t_list.c` - LPUSH, RPOP, etc. fire `NOTIFY_LIST`
- `t_set.c` - SADD, SREM, etc. fire `NOTIFY_SET`
- `t_hash.c` - HSET, HDEL, etc. fire `NOTIFY_HASH`
- `t_zset.c` - ZADD, ZREM, etc. fire `NOTIFY_ZSET`
- `t_stream.c` - XADD, XDEL, etc. fire `NOTIFY_STREAM`
- `db.c` - DEL, RENAME, etc. fire `NOTIFY_GENERIC`
- `expire.c` / `lazyfree.c` - expired/evicted keys fire `NOTIFY_EXPIRED` / `NOTIFY_EVICTED`
- `module.c` - modules fire `NOTIFY_MODULE` for custom events

## Subscribing to Notifications

Clients subscribe using standard SUBSCRIBE/PSUBSCRIBE:

```
SUBSCRIBE __keyevent@0__:expired     -- all expired keys in db 0
PSUBSCRIBE __keyspace@0__:user:*     -- all events on keys matching user:*
```

There is no special command for keyspace notifications - they are regular pub/sub channels with a reserved naming convention.

## Performance Notes

- When `notify-keyspace-events` is empty (default), the function returns after the module notification step. No string allocation or pub/sub work happens.
- The `dbid` to string conversion (`ll2string`) result is cached between the keyspace and keyevent publish calls to avoid redundant conversion.
- Channel name strings are constructed as sds and wrapped in temporary robj instances that are freed immediately after publishing.
