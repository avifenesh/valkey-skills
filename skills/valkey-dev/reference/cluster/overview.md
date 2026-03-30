# Cluster Subsystem Overview

Use when you need to understand how Valkey distributes data across nodes, how the cluster bus works, how nodes discover each other, or how client requests get routed to the correct shard.

Source files: `cluster.h`, `cluster.c`, `cluster_legacy.h`, `cluster_legacy.c`

---

## Hash Slot Model

The keyspace is divided into 16,384 slots. A key's slot is determined by CRC16 hashing:

```c
// cluster.c - keyHashSlot()
unsigned int keyHashSlot(const char *key, int keylen) {
    // If key contains {tag}, only the tag is hashed
    // Otherwise hash the whole key
    return crc16(key, keylen) & 0x3FFF;  // 0x3FFF = 16383
}
```

Hash tags (`{...}`) allow multi-key operations by forcing related keys into the same slot. Only the content between the first `{` and its matching `}` is hashed. Empty tags `{}` are ignored - the whole key is hashed.

The constant `CLUSTER_SLOTS` is defined as `1 << 14` (16384). Each node owns a subset of these slots, tracked as a bitmap in `clusterNode.slots[CLUSTER_SLOTS / 8]` (2048 bytes).

---

## Key Structs

### clusterNode (`cluster_legacy.h`)

Represents a single node in the cluster:

```c
struct _clusterNode {
    char name[CLUSTER_NAMELEN];             // 40-char hex SHA1 node ID
    char shard_id[CLUSTER_NAMELEN];         // Shard identifier
    int flags;                              // CLUSTER_NODE_PRIMARY | REPLICA | PFAIL | FAIL | ...
    uint64_t configEpoch;                   // Epoch for conflict resolution
    unsigned char slots[CLUSTER_SLOTS / 8]; // Bitmap of owned slots
    int numslots;                           // Count of owned slots
    clusterNode *replicaof;                 // Primary node (NULL if this is a primary)
    clusterNode **replicas;                 // Array of replica pointers
    int num_replicas;
    clusterLink *link;                      // Outbound TCP/IP link
    clusterLink *inbound_link;              // Inbound link from this node
    rax *fail_reports;                      // Failure reports from other nodes
    mstime_t ping_sent;                     // When last PING was sent
    mstime_t pong_received;                 // When last PONG was received
    mstime_t fail_time;                     // When FAIL flag was set
    long long repl_offset;                  // Last known replication offset
    // ...
};
```

### clusterState (`cluster_legacy.h`)

Global cluster state, accessible via `server.cluster`:

```c
struct clusterState {
    clusterNode *myself;                    // This node
    uint64_t currentEpoch;                  // Cluster-wide monotonic epoch
    int state;                              // CLUSTER_OK or CLUSTER_FAIL
    int size;                               // Number of primaries with at least one slot
    dict *nodes;                            // name -> clusterNode hash table
    dict *shards;                           // shard_id -> list(clusterNode)
    clusterNode *slots[CLUSTER_SLOTS];      // Slot-to-node mapping (fast lookup)
    dict *migrating_slots_to;               // Slots in MIGRATING state
    dict *importing_slots_from;             // Slots in IMPORTING state
    list *slot_migration_jobs;              // Atomic slot migration jobs (Valkey 9.0)

    // Failover election state
    mstime_t failover_auth_time;
    int failover_auth_count;                // Votes received
    int failover_auth_sent;
    uint64_t failover_auth_epoch;
    uint64_t lastVoteEpoch;                 // Last epoch we voted in

    // Manual failover state
    mstime_t mf_end;                        // 0 = no manual failover in progress
    clusterNode *mf_replica;
    long long mf_primary_offset;
    int mf_can_start;
    // ...
};
```

### clusterLink (`cluster_legacy.h`)

Encapsulates a TCP connection to a remote cluster node:

```c
typedef struct clusterLink {
    mstime_t ctime;                        // Link creation time
    connection *conn;                      // Connection to remote node
    list *send_msg_queue;                  // Outgoing message queue
    size_t head_msg_send_offset;           // Bytes already sent from head message
    char *rcvbuf;                          // Receive buffer
    size_t rcvbuf_len;                     // Used bytes in rcvbuf
    clusterNode *node;                     // Associated node (NULL if unknown)
    int inbound;                           // 1 if accepted from remote, 0 if we initiated
} clusterLink;
```

---

## Cluster Bus

Nodes communicate over a binary protocol on `port + 10000` (configurable via `cluster-port`). This is a full-mesh topology - every node connects to every other node.

The bus port is defined by `CLUSTER_PORT_INCR = 10000` in `cluster_legacy.h`. Initialization in `clusterInitLast()` opens the listener:

```c
listener->port = server.cluster_port ? server.cluster_port : port + CLUSTER_PORT_INCR;
```

### Message Format

All messages share a common header (`clusterMsg`, 2256 bytes minimum):

- `sig[4]` - Signature "RCmb" (Redis Cluster message bus)
- `totlen` - Total message length
- `ver` - Protocol version (currently 1)
- `type` - Message type (PING, PONG, MEET, FAIL, etc.)
- `currentEpoch` - Sender's view of the cluster epoch
- `configEpoch` - Sender's config epoch (or its primary's, if replica)
- `offset` - Replication offset
- `sender[40]` - Sender's node name
- `myslots[2048]` - Sender's slot bitmap
- `flags` - Sender's node flags

A lightweight header variant (`clusterMsgLight`, 16 bytes) exists for high-frequency messages like PUBLISH and MODULE that don't need gossip data.

### Message Types

| Type | Value | Purpose |
|------|-------|---------|
| PING | 0 | Heartbeat, carries gossip |
| PONG | 1 | Reply to PING/MEET, same format as PING |
| MEET | 2 | Force receiver to add sender to cluster |
| FAIL | 3 | Broadcast confirmed failure of a node |
| PUBLISH | 4 | Pub/Sub message propagation |
| FAILOVER_AUTH_REQUEST | 5 | Replica asking for votes |
| FAILOVER_AUTH_ACK | 6 | Primary granting vote to replica |
| UPDATE | 7 | Slot configuration update |
| MFSTART | 8 | Initiate manual failover |
| MODULE | 9 | Module-defined cluster message |
| PUBLISHSHARD | 10 | Sharded pub/sub propagation |

---

## Gossip Protocol

PING and PONG messages carry a gossip section - an array of `clusterMsgDataGossip` entries, each describing a random known node:

```c
typedef struct {
    char nodename[CLUSTER_NAMELEN]; // Node ID
    uint32_t ping_sent;             // Last PING sent time (seconds)
    uint32_t pong_received;         // Last PONG received (seconds)
    char ip[NET_IP_STR_LEN];       // IP address
    uint16_t port;                  // Client port
    uint16_t cport;                 // Cluster bus port
    uint16_t flags;                 // Node flags snapshot
} clusterMsgDataGossip;
```

Processing happens in `clusterProcessGossipSection()`. For each gossipped node:

1. If we know it and it is reported as PFAIL/FAIL by a voting primary, a failure report is added. Then `markNodeAsFailingIfNeeded()` checks if quorum is reached.
2. If we know it and it is reported as healthy, any failure report from the sender is removed.
3. If we don't know it and it has an address, a new node entry is created (discovered through gossip).

### Ping Frequency

`clusterCron()` (called ~10 times/second) randomly selects a node and pings the one with the oldest `pong_received`. Additionally, any node that hasn't been pinged within `cluster_node_timeout / 2` gets a PING.

---

## Node Discovery and Topology

New nodes join through `CLUSTER MEET <ip> <port>`:

1. The receiving node creates a `clusterNode` in HANDSHAKE state with a temporary random name.
2. On receiving the first PONG, the node's real name (from `msg->sender`) replaces the temporary name, and the HANDSHAKE flag is cleared.
3. The MEET flag ensures the receiver adds the sender unconditionally (unlike PING, which is ignored from unknown nodes).

Gossip propagates node information transitively. If node A knows B and B knows C, A will eventually learn about C through B's gossip sections. This is how the full mesh forms without every node needing to explicitly MEET every other.

Nodes in HANDSHAKE state that exceed `cluster_node_timeout` (minimum 1 second) are removed.

---

## MOVED and ASK Redirects

When a client sends a command to the wrong node, `getNodeByQuery()` in `cluster.c` determines the redirect:

**MOVED** - The slot is permanently owned by another node:
```
-MOVED 3999 127.0.0.1:6381
```
The client should update its slot routing table and retry. This is the steady-state redirect.

**ASK** - The slot is being migrated. Keys that still exist on the source are served locally; missing keys get an ASK redirect to the migration target:
```
-ASK 3999 127.0.0.1:6382
```
The client should send `ASKING` to the target, then retry the command. The client should NOT update its routing table (the migration is temporary).

**TRYAGAIN** - During migration, a multi-key command has some keys on the source and some already migrated to the target. The client should retry later.

The decision logic:
- Slot in MIGRATING state + missing keys + no existing keys = ASK redirect
- Slot in MIGRATING state + missing keys + some existing keys = TRYAGAIN
- Slot in IMPORTING state + client sent ASKING = serve locally
- Slot owned by another node = MOVED

---

## Cluster State Determination

`clusterUpdateState()` computes the overall cluster health:

1. **Full coverage check**: If `cluster-require-full-coverage` is on (default), every slot must be assigned to a non-FAIL node. Any gap means CLUSTER_FAIL.
2. **Majority partition check**: The number of reachable primaries (with slots) must form a majority (`size / 2 + 1`). If not, the cluster enters CLUSTER_FAIL with reason MINORITY_PARTITION.
3. **Startup delay**: A primary that just restarted waits before accepting writes, giving the cluster time to reconfigure.

---

## Key Lifecycle Functions

| Function | File | Purpose |
|----------|------|---------|
| `clusterInit()` | cluster_legacy.c | Allocate clusterState, load config, start bus |
| `clusterCron()` | cluster_legacy.c | Periodic: reconnect, ping, detect PFAIL, migration |
| `clusterProcessPacket()` | cluster_legacy.c | Handle incoming cluster bus messages |
| `clusterProcessGossipSection()` | cluster_legacy.c | Process gossip entries from PING/PONG |
| `clusterBeforeSleep()` | cluster_legacy.c | Deferred actions: failover, state update, config save |
| `getNodeByQuery()` | cluster.c | Route client command to correct node |
| `clusterRedirectClient()` | cluster.c | Send MOVED/ASK/TRYAGAIN error to client |
| `clusterUpdateState()` | cluster_legacy.c | Recompute CLUSTER_OK vs CLUSTER_FAIL |
| `keyHashSlot()` | cluster.c | CRC16 hash slot calculation |

---

## See Also

- [Cluster Failover](failover.md) - PFAIL/FAIL detection and replica election
- [Slot Migration](slot-migration.md) - Resharding via MIGRATE and atomic migration (9.0+)
- [Sentinel Mode](../sentinel/sentinel-mode.md) - Alternative HA for non-cluster deployments
- [Replication Overview](../replication/overview.md) - PSYNC and replication backlog for intra-shard sync
- [Event Loop](../architecture/event-loop.md) - Cluster bus uses ae file events; clusterCron runs in serverCron
- [Networking Layer](../architecture/networking.md) - Cluster bus uses the same connection abstraction as clients
- [Command Dispatch](../architecture/command-dispatch.md) - processCommand checks slot ownership before execution
- [kvstore](../valkey-specific/kvstore.md) - Per-slot hashtable organization in cluster mode
- [Hashtable](../data-structures/hashtable.md) - Backing structure for per-slot keyspaces
