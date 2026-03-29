# Rolling Upgrades

Use when upgrading Valkey with zero downtime in Sentinel or Cluster setups, performing planned primary swaps, or executing maintenance windows.

---

## General Rules

1. Always upgrade replicas before primaries
2. Replica RDB version must be >= primary RDB version
3. Do not run mixed minor versions in production long-term
4. Verify replication health after each node upgrade
5. Monitor cluster/sentinel state throughout the process

## Rolling Upgrade: Sentinel Setup

### Prerequisites

- At least one primary + two replicas + three Sentinels
- New Valkey version packages available on all hosts
- Maintenance window communicated (zero-downtime, but communicate anyway)

### Procedure

```bash
# Step 1: Verify current topology
valkey-cli -p 26379 SENTINEL masters
valkey-cli -p 26379 SENTINEL replicas mymaster
# Record: primary host/port, replica hosts/ports

# Step 2: Upgrade replicas one at a time
# On each replica host:
systemctl stop valkey
# Install new version (package manager or binary replacement)
systemctl start valkey

# Step 3: Verify replica rejoined and synced
valkey-cli -h <replica-host> INFO replication
# Confirm:
#   role:slave
#   master_link_status:up
#   master_sync_in_progress:0

# Wait for replication offset to converge before proceeding to next replica

# Step 4: Trigger failover to promote an upgraded replica
valkey-cli -p 26379 SENTINEL FAILOVER mymaster

# Step 5: Wait for failover to complete
valkey-cli -p 26379 SENTINEL masters
# Confirm: new primary is an upgraded node

# Step 6: Upgrade the old primary (now a replica)
systemctl stop valkey
# Install new version
systemctl start valkey

# Step 7: Verify final state
valkey-cli -p 26379 SENTINEL masters
valkey-cli -p 26379 SENTINEL replicas mymaster
# All nodes should be on the new version

# Step 8: Upgrade Sentinels (one at a time)
# On each Sentinel host:
systemctl stop valkey-sentinel
# Install new version
systemctl start valkey-sentinel
valkey-cli -p 26379 SENTINEL sentinels mymaster
```

### Coordinated Failover (Valkey 9.0+)

For planned maintenance, use coordinated failover instead of standard failover for less disruption:

```bash
valkey-cli -p 26379 SENTINEL FAILOVER mymaster COORDINATED
```

This performs a supervised handover between primary and replica, coordinating the switch with minimal client impact.

## Rolling Upgrade: Cluster Setup

### Prerequisites

- Cluster with at least 3 primaries, each with at least 1 replica
- New version packages on all hosts
- Cluster health verified: `valkey-cli --cluster check <host>:<port>`

### Procedure

Repeat the following for each shard:

```bash
# Step 1: Identify shard members
valkey-cli -p 7000 CLUSTER NODES
# Find the primary node-id and its replica node-ids for this shard

# Step 2: Upgrade replicas first
# On each replica host for this shard:
systemctl stop valkey
# Install new version
systemctl start valkey

# Step 3: Verify replica rejoined the cluster
valkey-cli -h <replica-host> -p <replica-port> INFO replication
# Confirm: role:slave, master_link_status:up

valkey-cli -p 7000 CLUSTER NODES
# Confirm: replica shows "slave" with "connected" status

# Step 4: Failover to promote upgraded replica
valkey-cli -h <replica-host> -p <replica-port> CLUSTER FAILOVER
# This blocks writes briefly, waits for replication sync, then swaps roles

# Step 5: Verify failover
valkey-cli -h <replica-host> -p <replica-port> ROLE
# Should return "master"

valkey-cli -p 7000 CLUSTER NODES
# Confirm: the upgraded node is now the primary for this shard

# Step 6: Upgrade old primary (now a replica)
systemctl stop valkey
# Install new version
systemctl start valkey

# Step 7: Verify old primary rejoined as replica
valkey-cli -h <old-primary> -p <port> INFO replication
# Confirm: role:slave, master_link_status:up

# Step 8: Run cluster health check
valkey-cli --cluster check <host>:<port>
# Confirm: all 16384 slots assigned, no errors

# Proceed to next shard
```

### Cluster Upgrade Order

When upgrading a cluster with many shards:

1. Upgrade all replicas across all shards first
2. Then failover and upgrade primaries one shard at a time
3. Never upgrade more than one primary simultaneously
4. After each failover, wait for the cluster to stabilize before proceeding

## Zero-Downtime Primary Swap

Use when replacing hardware, moving to a different host, or upgrading a standalone primary without Sentinel.

```bash
# Step 1: Start new instance as a replica of the current primary
valkey-server /etc/valkey/valkey.conf --replicaof <old-primary-host> 6379

# Step 2: Wait for sync completion
valkey-cli -h <new-host> -p 6379 INFO replication
# Watch for:
#   master_link_status:up
#   master_sync_in_progress:0
#   Replication offset converging with primary

# Step 3: Verify data
valkey-cli -h <new-host> DBSIZE
# Should match the primary's DBSIZE

# Step 4: Switch client connections
# Update DNS, load balancer, or application config to point to new host
# At this point, reads go to new host but writes still go to old primary

# Step 5: Promote new instance
valkey-cli -h <new-host> -p 6379 REPLICAOF NO ONE

# Step 6: Decommission old primary
valkey-cli -h <old-primary-host> SHUTDOWN NOSAVE
```

### With WAIT for Safety

For critical data, use `WAIT` before the switchover to ensure writes are replicated:

```bash
# On the old primary, after the last critical write:
valkey-cli -h <old-primary-host> WAIT 1 5000
# Waits up to 5 seconds for at least 1 replica to acknowledge

# Then proceed with client switch and promotion
```

## Health Checks Between Steps

Run these between each upgrade step:

```bash
# Sentinel setup
valkey-cli -p 26379 SENTINEL masters        # primary info
valkey-cli -p 26379 SENTINEL replicas mymaster  # replica status

# Cluster setup
valkey-cli --cluster check <host>:<port>    # slot coverage, connectivity
valkey-cli -p 7000 CLUSTER INFO             # cluster_state should be "ok"

# Any setup
valkey-cli INFO replication                 # replication lag, link status
valkey-cli INFO server | grep valkey_version  # confirm version
```

## Rollback Plan

If the upgraded version causes issues:

### Sentinel Rollback

```bash
# Failover back to an old-version replica (if one remains)
valkey-cli -p 26379 SENTINEL FAILOVER mymaster

# Or stop the upgraded node and reinstall the old version
systemctl stop valkey
# Reinstall old version
systemctl start valkey
```

### Cluster Rollback

```bash
# Failover the affected shard back to the old-version replica
valkey-cli -p <old-replica-port> CLUSTER FAILOVER

# Downgrade the problematic node
systemctl stop valkey
# Reinstall old version
systemctl start valkey
```

Key constraint: downgrading across RDB major versions may fail if the new version wrote data in a newer RDB format. Always keep backups from before the upgrade.

## See Also

- [Version Compatibility](compatibility.md) - RDB versions and replication compatibility
- [Redis Migration](migration.md) - migrating from Redis to Valkey
- [Sentinel Deployment Runbook](../sentinel/deployment-runbook.md) - Sentinel failover procedures
- [Cluster Operations](../cluster/operations.md) - cluster failover procedures
- [Production Checklist](../production-checklist.md) - pre-upgrade verification
- [See valkey-dev: cluster/failover](../valkey-dev/reference/cluster/failover.md) - cluster failover internals
- [See valkey-dev: cluster/slot-migration](../valkey-dev/reference/cluster/slot-migration.md) - slot migration details
