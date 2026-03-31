# Cluster Topology Internals

Use when working on cluster slot mapping, failover handling, MOVED/ASK redirect logic, or topology refresh.

## Slot Mapping

GLIDE uses the `SlotMap` from the redis crate to track which node owns which slot range (0-16383). The slot map is refreshed:
1. On initial connection
2. On MOVED redirect (stale slot mapping)
3. On ASK redirect (slot migration in progress)
4. Periodically via topology refresh

## MOVED/ASK Handling

- **MOVED**: slot permanently moved to another node. Update slot map, retry on new node.
- **ASK**: slot temporarily being migrated. Send ASKING + command to the indicated node, don't update slot map.

## Topology Refresh

Cluster topology is fetched via `CLUSTER SLOTS` or `CLUSTER SHARDS` (Valkey 7.0+). On refresh:
1. Build new slot map
2. Compare with current connections
3. Create connections to new nodes
4. Close connections to removed nodes
5. Trigger PubSub resubscription for affected slots

## Routing Decisions (`request_type.rs`)

Each command type has routing info:
- **Single slot**: route to the node owning the slot for the command's key
- **All nodes**: broadcast to all primaries (e.g., FLUSHALL, DBSIZE)
- **Random node**: any node (e.g., PING, INFO)
- **Primary preferred**: prefer primary, fall back to replica

Multi-key commands must target the same slot (hash tags help: `{same-slot}:key1`, `{same-slot}:key2`).

## Connection Pool

Per-node connection pool with:
- Configurable min/max connections
- Auto-reconnection with exponential backoff
- Health checking via PING
- Connection naming for debug (CLIENT SETNAME)
