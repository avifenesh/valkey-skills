# Client Tracking

Use when implementing client-side caching, understanding invalidation messages,
or debugging why clients receive (or fail to receive) cache invalidations.

Source: `src/tracking.c`

## Contents

- Overview (line 26)
- Global State (line 33)
- Broadcast State (line 49)
- Enabling and Disabling (line 60)
- Default Mode: Key-Based Tracking (line 88)
- Broadcast Mode: Prefix-Based Tracking (line 125)
- Invalidation Message Format (line 155)
- Flush Handling (line 175)
- Memory Pressure: Table Eviction (line 181)
- Pending Key Invalidations (line 193)
- Prefix Collision Detection (line 206)
- INFO Metrics (line 212)
- See Also (line 221)

---

## Overview

Client tracking enables server-assisted client-side caching. When a client
reads a key, the server remembers the association. When that key is later
modified, the server sends an invalidation message to all clients that may have
cached it. Two modes exist: default (key-based) and broadcasting (prefix-based).

## Global State

```c
rax *TrackingTable = NULL;        /* key -> rax of client IDs */
rax *PrefixTable = NULL;          /* prefix -> bcastState */
uint64_t TrackingTableTotalItems = 0;  /* Sum of all client IDs across all keys */
robj *TrackingChannelName;        /* "__redis__:invalidate" (legacy name, kept for RESP2 pubsub compat) */
```

Both tables are radix trees (rax). They are created lazily on the first call to
`enableTracking()` and are never NULL after that point.

The server also tracks `server.tracking_clients` (count of clients with
tracking enabled) and `server.tracking_table_max_keys` (configurable limit on
TrackingTable size).

## Broadcast State

For prefix-based tracking, each registered prefix has:

```c
typedef struct bcastState {
    rax *keys;    /* Keys modified in the current event loop cycle. */
    rax *clients; /* Clients subscribed to this prefix. */
} bcastState;
```

## Enabling and Disabling

### enableTracking

```c
void enableTracking(client *c, uint64_t redirect_to,
                    struct ClientFlags options, robj **prefix, size_t numprefix);
```

Sets tracking flags on the client. If broadcasting mode is requested, registers
the client for each specified prefix in the PrefixTable. If no prefixes are
given in broadcast mode, the empty prefix "" is used (matches all keys).

Client flags managed:
- `tracking` - tracking is active
- `tracking_bcast` - broadcast mode
- `tracking_optin` - opt-in mode (only track after CLIENT CACHING YES)
- `tracking_optout` - opt-out mode (track by default, skip after CLIENT CACHING NO)
- `tracking_noloop` - do not send invalidations for keys modified by this client
- `tracking_caching` - transient flag set by CLIENT CACHING YES/NO

### disableTracking

Decrements `server.tracking_clients`, clears all flags. For broadcast clients,
iterates all registered prefixes, removes the client from each bcastState, and
frees empty prefix entries. Client IDs left in the TrackingTable are cleaned up
lazily (not eagerly removed) to avoid expensive scans.

## Default Mode: Key-Based Tracking

### trackingRememberKeys

```c
void trackingRememberKeys(client *tracking, client *executing);
```

Called after a read-only command completes. Extracts keys from the command using
`getKeysFromCommand()`, then for each key:
1. Looks up (or creates) a rax in TrackingTable keyed by the key name
2. Inserts the tracking client's ID into that rax
3. Increments TrackingTableTotalItems

OPTIN/OPTOUT logic: if optin is set and CLIENT CACHING YES was not issued,
keys are not tracked. If optout is set and CLIENT CACHING NO was issued,
keys are not tracked. Pubsub shard channels are excluded.

### trackingInvalidateKey

```c
void trackingInvalidateKey(client *c, robj *keyobj, int bcast);
```

Called from `signalModifiedKey()` when a key changes. For each client ID in the
key's rax entry:
- Skips NULL clients, non-tracking clients, and broadcast-mode clients
- Skips the current client if NOLOOP is set
- If the target is the current client and it has `flag.executing_command` set,
  defers the invalidation to `server.tracking_pending_keys` (to avoid
  interleaving with command response)
- Otherwise calls `sendTrackingMessage()` immediately

After notifying all clients, the key's rax is freed and removed from the
TrackingTable. This means each key modification clears all tracking state for
that key - clients must re-read to re-register.

## Broadcast Mode: Prefix-Based Tracking

### trackingRememberKeyToBroadcast

```c
void trackingRememberKeyToBroadcast(client *c, char *keyname, size_t keylen);
```

Called when a key is modified and broadcast clients exist. Iterates the
PrefixTable and for each prefix that matches the key name (prefix comparison),
inserts the key into that prefix's `bcastState.keys` rax. The modifying client
pointer is stored as the value (used for NOLOOP filtering).

### trackingBroadcastInvalidationMessages

```c
void trackingBroadcastInvalidationMessages(void);
```

Called at the end of each event loop cycle (in `beforeSleep`). For each prefix
in PrefixTable that has accumulated keys:
1. Builds a single RESP array of all modified key names
2. Sends it to every subscribed client
3. For NOLOOP clients, builds a filtered array excluding keys modified by that
   client
4. Clears the accumulated keys

This batching means broadcast invalidations are sent once per event loop cycle,
not per-key.

## Invalidation Message Format

### sendTrackingMessage

```c
void sendTrackingMessage(client *c, char *keyname, size_t keylen, int proto);
```

Handles redirection and protocol differences:

- **RESP3 clients**: Push message `["invalidate", [key1, key2, ...]]`
- **RESP2 with redirection**: Pubsub message on `__redis__:invalidate` channel (legacy name retained for compatibility)
- **RESP2 without redirection**: Cannot send push messages, message is dropped

If redirection is configured but the target client is gone, the original client
receives a `tracking-redir-broken` push notification with the dead client ID.

When `proto` is non-zero, the keyname buffer is already RESP-encoded (used for
broadcast batches and FLUSHALL null notifications).

## Flush Handling

`trackingInvalidateKeysOnFlush()` sends a RESP NULL to all tracking clients to
indicate all keys are now invalid. The TrackingTable is then freed (async if
the flush is async) and replaced with a fresh empty rax.

## Memory Pressure: Table Eviction

```c
void trackingLimitUsedSlots(void);
```

Called periodically. If `server.tracking_table_max_keys > 0` and the
TrackingTable exceeds this limit, the function evicts random keys by walking
the rax and calling `trackingInvalidateKey()` for each (which sends
invalidations to affected clients). Effort scales with repeated failures
(100 * (timeout_counter + 1) per call).

## Pending Key Invalidations

```c
void trackingHandlePendingKeyInvalidations(void);
```

Drains `server.tracking_pending_keys` after command execution completes. This
prevents invalidation messages from being interleaved with the command response
or transaction response. Only drains when `server.execution_nesting == 0`.

A NULL entry in the pending list means "send null" (all keys invalid, from
FLUSHALL).

## Prefix Collision Detection

`checkPrefixCollisionsOrReply()` prevents a client from registering overlapping
prefixes (e.g. "foo" and "foobar") since both would fire for the same keys.
Checked both against existing prefixes and within the new set being registered.

## INFO Metrics

- `tracking_clients` - number of clients with tracking enabled
- `tracking_total_keys` - raxSize(TrackingTable)
- `tracking_total_items` - TrackingTableTotalItems (sum of client IDs across keys)
- `tracking_total_prefixes` - raxSize(PrefixTable)

---

## See Also

- [Pub/Sub](../pubsub/pubsub.md) - RESP2 invalidation messages are delivered over the pub/sub channel `__redis__:invalidate`; RESP3 uses push messages instead
- [Keyspace Notifications](../pubsub/notifications.md) - a separate notification system; tracking sends targeted invalidations to caching clients, while keyspace notifications broadcast all key events
- [Database Management](../config/db-management.md) - `signalModifiedKey()` calls `trackingInvalidateKey()` on every key mutation
- [Radix Tree (rax)](../data-structures/rax.md) - both TrackingTable and PrefixTable are rax structures; `freeTrackingRadixTreeAsync()` uses lazy freeing for large trees
- [Lazy Freeing](../memory/lazy-free.md) - `freeTrackingRadixTreeAsync()` submits the TrackingTable to a BIO thread on FLUSHALL ASYNC
