# Valkey Upgrades and Redis-to-Valkey Migration - Research

> Deep research compiled from official Valkey documentation, release notes,
> blog posts, community reports, and cloud provider guides.
> Last updated: 2026-03-29

---

## Table of Contents

1. [Version Compatibility Matrix](#version-compatibility-matrix)
2. [Redis-to-Valkey Migration (Drop-in Replacement)](#redis-to-valkey-migration)
3. [Zero-Downtime Upgrade Procedure (Standalone)](#zero-downtime-upgrade-standalone)
4. [Rolling Upgrade Procedure (Cluster)](#rolling-upgrade-cluster)
5. [Rolling Upgrade Procedure (Sentinel)](#rolling-upgrade-sentinel)
6. [Kubernetes / Helm Migrations](#kubernetes-helm-migrations)
7. [AWS ElastiCache to Self-Hosted Valkey](#aws-elasticache-to-self-hosted)
8. [Breaking Changes Between Valkey Major Versions](#breaking-changes)
9. [Configuration Compatibility: Redis 7.x vs Valkey 8.x/9.x](#configuration-compatibility)
10. [Data Validation After Migration](#data-validation)
11. [Rollback Procedures](#rollback-procedures)
12. [Pitfalls and Gotchas from Real Deployments](#pitfalls-and-gotchas)
13. [Downtime Estimates by Method](#downtime-estimates)
14. [Operational Lessons from Large-Scale Deployments](#operational-lessons)
15. [Sources](#sources)

---

## Version Compatibility Matrix

### Valkey Release History

| Version | Release Date | Based On | Compatibility |
|---------|-------------|----------|---------------|
| Valkey 8.0.0 GA | Sep 15, 2024 | Redis OSS 7.2.4 fork | Fully compatible with Redis OSS 7.2.4 |
| Valkey 8.0.1 | Oct 1, 2024 | 8.0 branch | Security fixes (CVE-2024-31449, CVE-2024-31227, CVE-2024-31228) |
| Valkey 8.0.2 | Jan 6, 2025 | 8.0 branch | Security fixes (CVE-2024-46981, CVE-2024-51741) |
| Valkey 8.0.3 | Apr 23, 2025 | 8.0 branch | Security + bug fixes |
| Valkey 8.0.4 | Jul 7, 2025 | 8.0 branch | Security (CVE-2025-32023, CVE-2025-48367) |
| Valkey 8.0.5 | Aug 22, 2025 | 8.0 branch | Security + 12 bug fixes |
| Valkey 8.0.6 | Oct 3, 2025 | 8.0 branch | Security (4 Lua CVEs) |
| Valkey 8.0.7 | Feb 23, 2026 | 8.0 branch | Security (CVE-2026-21863, CVE-2025-67733) |
| Valkey 8.1.0 GA | Mar 31, 2025 | 8.0 + enhancements | Compatible with all previous Valkey + Redis OSS 7.2.4 |
| Valkey 8.1.1 | Apr 23, 2025 | 8.1 branch | Security (CVE-2025-21605) |
| Valkey 8.1.2 | Jun 11, 2025 | 8.1 branch | CVE fix for valkey-check-aof |
| Valkey 8.1.3 | Jul 7, 2025 | 8.1 branch | Security (CVE-2025-32023, CVE-2025-48367) |
| Valkey 8.1.4 | Oct 3, 2025 | 8.1 branch | Security (4 Lua CVEs) |
| Valkey 8.1.5 | Dec 4, 2025 | 8.1 branch | Fix loading AOF from future Valkey versions |
| Valkey 8.1.6 | Feb 23, 2026 | 8.1 branch | Security (CVE-2026-21863, CVE-2025-67733) |
| Valkey 9.0.0 GA | Oct 21, 2025 | New major | New features, not backward-compatible with Redis |
| Valkey 9.0.1 | Dec 9, 2025 | 9.0 branch | MODERATE - bug fixes |
| Valkey 9.0.2 | Feb 3, 2026 | 9.0 branch | HIGH - critical hash field expiration bugs |
| Valkey 9.0.3 | Feb 23, 2026 | 9.0 branch | Security (3 CVEs) |

### Cross-Version Replication Compatibility

Valkey maintains backward-compatible replication within the same protocol version:

- **Valkey 8.x replicas can replicate from Redis 7.2.x primaries** - this is the basis for zero-downtime migration from Redis
- **Valkey 9.x replicas can replicate from Valkey 8.x primaries** - confirmed in rolling upgrade documentation
- **Mixed clusters**: during rolling upgrades, mixed-version clusters function correctly as long as you upgrade replicas before primaries
- **RDB format**: Valkey 8.1.5 added a fix for "loading AOF files from future Valkey versions", indicating forward-compatible persistence where possible

### Client Library Compatibility

- Valkey 8.x is wire-protocol compatible with Redis; existing Redis clients (redis-py, ioredis, jedis, etc.) work without changes
- Valkey 9.x new features (hash field expiration, numbered databases in cluster) require updated client libraries
- `REDISCLI_AUTH` environment variable is still supported alongside `VALKEYCLI_AUTH` (added in 9.0)
- Sentinel commands: 8.0 RC2 added inclusive-language aliases (`GET-PRIMARY-ADDR-BY-NAME`, `PRIMARY`, `PRIMARIES`, `IS-PRIMARY-DOWN-BY-ADDR`) while retaining old names

---

## Redis-to-Valkey Migration

### Why It's a Drop-in Replacement (8.x)

Valkey 8.0 was forked from Redis OSS 7.2.4. The official release notes explicitly state:

> "This release is fully compatible with Redis OSS 7.2.4."

This means:
- Same RDB/AOF persistence formats
- Same RESP protocol
- Same command set
- Same configuration parameters (with additions)
- Same replication protocol

### Step-by-Step: Standalone Redis to Valkey 8.x

**Method 1: Replication-Based (Zero Downtime)**

1. Install Valkey on a new server or same server on a different port
2. Configure the new Valkey instance as a replica of the Redis primary:
   ```
   replicaof <redis-primary-ip> <redis-primary-port>
   ```
3. If Redis has authentication, configure:
   ```
   primaryauth <redis-password>
   ```
4. Wait for initial replication sync to complete (check replica log file)
5. Verify sync using `INFO replication` - confirm `master_link_status:up`
6. Verify key count matches: `DBSIZE` on both instances
7. Allow writes on the replica: `CONFIG SET replica-read-only no`
8. Pause clients on old primary: `CLIENT PAUSE <timeout-ms>`
9. Promote Valkey replica: `REPLICAOF NO ONE`
10. Redirect all clients to the new Valkey instance
11. Shut down old Redis instance

**Method 2: RDB Snapshot (Brief Downtime)**

1. On Redis: `BGSAVE` to create an RDB snapshot
2. Stop Redis
3. Copy the RDB file to the Valkey data directory
4. Start Valkey with the same configuration (renaming `redis.conf` directives as needed)
5. Verify data loaded correctly

**Method 3: AOF-Based**

1. On Redis: `BGREWRITEAOF`
2. Wait for AOF rewrite to complete
3. Stop Redis
4. Copy AOF files to Valkey data directory
5. Start Valkey

### Step-by-Step: Redis Cluster to Valkey 8.x Cluster

Use the replication-based rolling upgrade approach (see [Rolling Upgrade - Cluster](#rolling-upgrade-cluster) below). The process is:

1. For each shard, add a Valkey 8.x node as a replica of the Redis primary
2. Wait for replication sync
3. Trigger `CLUSTER FAILOVER` on the Valkey replica to promote it
4. Repeat for all shards
5. Remove old Redis nodes

### Step-by-Step: Redis Sentinel to Valkey 8.x Sentinel

1. Replace Sentinel binaries one at a time (Sentinel instances)
2. Replace replica instances one at a time
3. Use `SENTINEL FAILOVER <master-name>` to promote a Valkey replica as new primary
4. Replace the old Redis primary (now demoted to replica)

---

## Zero-Downtime Upgrade (Standalone)

Source: Valkey official administration documentation.

### Official Procedure

> "Valkey is designed to be a long-running process. You can modify many
> configuration options without a restart using the CONFIG SET command."

For upgrades requiring a binary restart:

1. **Set up the new Valkey instance as a replica of the current instance**
   - Use a different server, or a different port on the same server
   - Ensure sufficient RAM for two instances simultaneously

2. **Wait for replication sync to complete**
   - Check the replica's log file for sync completion
   - Use `INFO replication` to confirm `master_link_status:up`

3. **Verify data integrity**
   - Compare key counts using `INFO keyspace` or `DBSIZE`
   - Use `valkey-cli` to spot-check values

4. **Allow writes to the replica**
   ```
   CONFIG SET replica-read-only no
   ```

5. **Switch clients**
   - Use `CLIENT PAUSE <timeout>` on the old primary to prevent writes during switchover
   - Redirect all clients to the new instance

6. **Promote the replica**
   ```
   REPLICAOF NO ONE
   ```

7. **Shut down the old instance**
   - Verify via `MONITOR` that no clients are still connecting to the old instance

### Important Notes

- **Partial resync on restart**: Use `SHUTDOWN` (not `kill -9`) to perform a clean save. This stores replication info in the RDB file, enabling partial resync on restart rather than a full sync.
- **AOF caution**: It is not possible to partially sync a replica that restarted via the AOF file. Convert to RDB persistence before shutting down if you need partial resync capability.
- **repl-backlog-size**: Valkey 8.0 RC2 increased the default from 1 MB to 10 MB. For upgrade scenarios, ensure the backlog is large enough to cover the switchover window.

---

## Rolling Upgrade (Cluster)

Source: Valkey cluster tutorial documentation.

### Official Rolling Upgrade Procedure

Repeat the following for **each shard** (a primary and its replicas):

#### Step 1: Add Upgraded Replicas

Add one or more upgraded Valkey nodes as new replicas to the primary:

```bash
# Option A: Using valkey-cli
valkey-cli --cluster add-node <new-node-ip>:<port> <existing-node-ip>:<port> \
  --cluster-replica --cluster-master-id <primary-node-id>

# Option B: Manual
valkey-cli -h <new-node-ip> -p <port> CLUSTER MEET <primary-ip> <primary-port>
valkey-cli -h <new-node-ip> -p <port> CLUSTER REPLICATE <primary-node-id>
```

This step is optional but recommended - it ensures replica count is maintained during the upgrade.

**Alternative**: Upgrade existing replicas one at a time (stop, upgrade binary, restart). Fewer replicas are online during each individual upgrade.

#### Step 2: Upgrade Old Replicas (Optional)

If keeping old replicas, restart them with the updated Valkey version. Skip if replacing all old nodes with new ones.

#### Step 3: Select and Verify the New Primary

Select one of the upgraded replicas to become the new primary. Verify it has caught up:

```bash
# Check initial sync is complete
valkey-cli -h <replica-ip> -p <port> INFO replication
# Look for: master_link_status:up

# Compare replication offsets
valkey-cli -h <primary-ip> -p <port> INFO replication | grep master_repl_offset
valkey-cli -h <replica-ip> -p <port> INFO replication | grep master_repl_offset
# Offsets should match or be very close
```

Under constant write load, offsets may never be exactly equal. Wait a few seconds to minimize the difference.

#### Step 4: Verify Cluster Awareness

Ensure all nodes in the cluster know about the new replica:

```bash
# Check from multiple nodes
valkey-cli -h <any-node-ip> -p <port> CLUSTER NODES | grep <new-replica-id>
```

Wait and recheck if the new node is not yet visible to all nodes.

#### Step 5: Trigger Manual Failover

```bash
valkey-cli -h <replica-ip> -p <port> CLUSTER FAILOVER
```

**Manual failover is safer than crash-triggered failover** because:
- Clients writing to the old primary are blocked during failover
- The replica waits until it has processed all replication data from the primary
- Only then does the failover complete, preventing data loss

#### Step 6: Verify Failover Completion

```bash
# Check the replica is now primary
valkey-cli -h <replica-ip> -p <port> ROLE
# Should return: master

# Or check via INFO
valkey-cli -h <replica-ip> -p <port> INFO replication | grep role
# Should return: role:master

# Or check cluster state
valkey-cli -h <any-node-ip> -p <port> CLUSTER NODES
```

#### Step 7: Clean Up

- Take the old primary (now a replica) out of service, or upgrade it and re-add as replica
- Remove any extra replicas added for redundancy during upgrade

#### Step 8: Repeat for Each Shard

Process all shards sequentially. After all shards are done, verify cluster health:

```bash
valkey-cli --cluster check <any-node-ip>:<port>
```

### Cluster-Specific Considerations for Valkey 9.0 Upgrades

- **Atomic Slot Migration**: New in 9.0. Mixed 8.x/9.0 clusters during rolling upgrade will use legacy (key-by-key) migration. The `SYNCSLOTS CAPA` mechanism (introduced in 9.0-rc3) handles forward compatibility.
- **Module compatibility**: Modules must explicitly opt in to Atomic Slot Migration (ASM) support. Clusters loading modules without ASM support will have ASM disabled. Check your modules before upgrading.
- **Numbered databases in cluster**: 9.0 adds multi-database support to cluster mode. Existing clusters using only db 0 are unaffected.
- **CLUSTER SETSLOT replication**: Since 8.0, `CLUSTER SETSLOT` is replicated to replicas running 8.0+. During mixed-version rolling upgrades, older replicas may not receive these replication updates.
- **Light-weight cluster messages**: 9.0 uses light-weight messages between nodes. Send "duplicate multi meet packet only for nodes which support it" in mixed clusters (fix in 9.0.1).
- **cluster-manual-failover-timeout**: New config in 8.1 / 9.0 allows controlling the timeout for manual failover operations.

---

## Rolling Upgrade (Sentinel)

Source: Valkey Sentinel documentation.

### Procedure

Sentinel-managed deployments follow a similar pattern to standalone but with automated failover awareness:

1. **Upgrade Sentinel instances first** (one at a time)
   - Stop a Sentinel, upgrade the binary, restart
   - Sentinel state is persisted in `sentinel.conf` and reloaded on restart
   - Repeat for each Sentinel (maintain quorum throughout)

2. **Upgrade replica instances** (one at a time)
   - Stop the replica
   - Upgrade the binary
   - Restart - it will rejoin and resync with the primary

3. **Perform manual failover**
   ```bash
   valkey-cli -p 26379 SENTINEL FAILOVER <master-name>
   ```
   This promotes a Valkey replica to primary.

4. **Upgrade the old primary** (now a replica after failover)
   - Stop, upgrade binary, restart
   - It will automatically connect as a replica of the new primary

### Sentinel-Specific Gotchas

- **ACL regression in 9.0**: Sentinel 9.0.0 had a regression requiring `+failover` ACL permission in the failover path. Fixed in 9.0.1.
- **Inclusive language commands**: Valkey 8.0 RC2 added `GET-PRIMARY-ADDR-BY-NAME`, `PRIMARY`, `PRIMARIES`, `IS-PRIMARY-DOWN-BY-ADDR` as aliases. Old command names still work.
- **sentinel.conf validity**: Valkey 8.0.1 fixed an issue where the default `sentinel.conf` was invalid.
- **Keep quorum**: Never take more than (n-1)/2 Sentinels offline simultaneously (for a 3-Sentinel setup, upgrade one at a time).

---

## Kubernetes / Helm Migrations

Source: Valkey Helm blog post (2026-01-06).

### Background

Bitnami changed how it publishes container images and Helm charts. This can cause:
- Rollout failures (`ImagePullBackOff`, auth/404 errors)
- Cluster drift between staging and production
- "Invisible" upgrades when a moved tag points to a new digest
- Failed rollbacks when old images can't be pulled

### Official Valkey Helm Chart

The community created an official chart at `valkey-io/valkey-helm`.

```bash
helm repo add valkey https://valkey.io/valkey-helm/
helm repo update
```

**Current capabilities** (as of v0.9.x):
- Standalone instance (with or without persistence)
- Replicated read-heavy workloads (primary-replica topology)
- ACL-based authentication
- TLS encryption
- Prometheus metrics exporter

**Upcoming features**: Sentinel HA (#22), persistence controls (#88), Cluster support (#18).

### Migrating from Bitnami to Official Valkey Helm Chart

**In-place upgrade is NOT possible** due to incompatible naming conventions, labels, and StatefulSet structures. Data migration is required.

#### Step 1: Identify Existing Deployment

```bash
kubectl get pods --all-namespaces -l app.kubernetes.io/name=valkey \
  -o custom-columns=Pod:.metadata.name,Namespace:.metadata.namespace,Instance:.metadata.labels.app\\.kubernetes\\.io\\/instance

export NAMESPACE="apps-test"
export INSTANCE="valkey-bitnami"

export SVCPRIMARY=$(kubectl get service -n $NAMESPACE \
  -l app.kubernetes.io/instance=$INSTANCE,app.kubernetes.io/name=valkey,app.kubernetes.io/component=primary \
  -o jsonpath='{.items[0].metadata.name}')

export PASS=$(kubectl get secret -n $NAMESPACE \
  -l app.kubernetes.io/name=valkey,app.kubernetes.io/instance=$INSTANCE \
  -o jsonpath='{.items[0].data.valkey-password}' | base64 -d)
```

#### Step 2: Deploy New Valkey Instance

```yaml
# values.yaml
auth:
  enabled: true
  aclUsers:
    default:
      password: "$PASS"
      permissions: "~* &* +@all"
replica:
  enabled: true
  replicas: 3
  persistence:
    size: 8Gi
valkeyConfig: |
  appendonly yes
```

```bash
export NEWINSTANCE="valkey"
helm install -n $NAMESPACE $NEWINSTANCE valkey/valkey -f values.yaml
```

#### Step 3: Enable Replication from Old to New

```bash
# On the new instance
valkey-cli config set primaryauth $PASS
valkey-cli replicaof $SVCPRIMARY 6379

# Verify
valkey-cli info replication | grep '^\(role\|master_host\|master_link_status\)'
# Expect: role:slave, master_link_status:up
```

#### Step 4: Failover

```bash
export PODPRIMARY=$(kubectl get pod -n $NAMESPACE $NEWINSTANCE-0 \
  -o jsonpath='{.status.podIP}')
current-valkey-cli failover to $PODPRIMARY 6379

# Verify
new-valkey-cli info | grep '^role:'
# Expect: role:master
```

#### Step 5: Switch Clients

```bash
echo "Read-Write: $NEWINSTANCE.$NAMESPACE.svc.cluster.local"
echo "Read-only: $NEWINSTANCE-read.$NAMESPACE.svc.cluster.local"
```

Plan for a brief maintenance window to ensure all writes are fully replicated before switching endpoints.

---

## AWS ElastiCache to Self-Hosted Valkey

### Migration Approaches

#### Method 1: RDB Export and Import

1. **Create a snapshot** of the ElastiCache cluster via AWS Console or CLI
2. **Export the snapshot to S3**:
   ```bash
   aws elasticache copy-snapshot \
     --source-snapshot-name my-snapshot \
     --target-snapshot-name my-snapshot-export \
     --target-bucket my-s3-bucket
   ```
3. **Download the RDB file** from S3
4. **Load into Valkey**:
   - Place the RDB file in the Valkey data directory
   - Start Valkey (it will load the RDB on startup)

**Downtime**: Duration of snapshot creation + download + Valkey startup with data load. For large datasets (100+ GB), this can be 30-60+ minutes.

#### Method 2: Replication-Based (Lower Downtime)

1. **Set up a Valkey instance** reachable from the ElastiCache VPC
2. **Configure Valkey as replica** of ElastiCache:
   ```
   replicaof <elasticache-primary-endpoint> <port>
   ```
3. **Wait for sync**, then promote and switch clients

**Note**: This requires network connectivity between ElastiCache and your Valkey host. ElastiCache must be in a VPC accessible from where Valkey runs. If using a different cloud or on-prem, you may need VPN or Direct Connect.

**Downtime**: Only the client switchover window (seconds to low minutes).

#### Method 3: Dual-Write During Transition

1. Deploy Valkey alongside ElastiCache
2. Modify application to write to both ElastiCache and Valkey
3. Use a backfill process (SCAN + DUMP/RESTORE) to copy existing keys
4. Once backfill is complete, validate data parity
5. Switch reads to Valkey
6. Stop writes to ElastiCache
7. Decommission ElastiCache

**Downtime**: Zero application downtime, but requires code changes.

### ElastiCache-Specific Gotchas

- **Parameter groups**: ElastiCache uses parameter groups instead of `valkey.conf`. Export your parameter group settings and translate them to Valkey config.
- **AUTH token**: ElastiCache in-transit encryption uses an AUTH token. Ensure this is configured on the Valkey side if using replication-based migration.
- **Cluster mode**: ElastiCache cluster mode uses the same slot-based sharding as Valkey Cluster. The migration strategy maps directly.
- **Enhanced I/O**: ElastiCache's enhanced I/O multiplexing is proprietary. Valkey 8.0+ has its own I/O threading (`io-threads` config).
- **Backup window**: ElastiCache automated backups can cause latency spikes. Disable or schedule around them during migration.
- **Security groups**: Ensure your Valkey deployment has equivalent network security to the ElastiCache security groups.
- **EC2 considerations** (from Valkey admin docs):
  - Use HVM-based instances, not PV-based
  - EBS volumes can have high latency - consider diskless replication: `repl-diskless-sync yes`

---

## Breaking Changes Between Valkey Major Versions

### Valkey 8.0 (from Redis 7.2.4)

**Not breaking** - fully compatible with Redis 7.2.4. The following are *additions*:

- Dual-channel replication (new feature, opt-in)
- I/O threading improvements
- New inclusive-language Sentinel commands (old commands still work)
- `repl-backlog-size` default changed from 1 MB to 10 MB
- Binary renamed from `redis-server` to `valkey-server`, `redis-cli` to `valkey-cli` (old names may still work depending on install method)

### Valkey 8.0 to 8.1

**Not breaking** - 8.1 is explicitly "fully compatible with all previous Valkey releases as well as Redis OSS 7.2.4."

Additions:
- SIMD optimizations for BITCOUNT
- Embedded hash values for lower memory
- `cluster-manual-failover-timeout` config
- Module API bypass flag
- `TCP_NODELAY` enabled by default for cluster/replication connections
- Valkey 8.1.5: fix for loading AOF files from future Valkey versions

### Valkey 8.x to 9.0

**Contains breaking changes** and new features not backward-compatible with Redis:

**New features requiring awareness**:
- **Atomic Slot Migration (ASM)**: Replaces key-by-key migration. Modules must opt in.
- **Hash field expiration**: New commands (HEXPIRE, HEXPIREAT, HGETEX, HSETEX, HTTL, etc.)
- **Numbered databases in cluster mode**: Breaks the Redis assumption that cluster = db 0 only.
- **DELIFEQ command**: New conditional delete.
- **Multipath TCP (MPTCP)**: New transport option.
- **CLUSTER MIGRATESLOTS**: New command for atomic slot migration.
- **CLUSTER FLUSHSLOT**: New command.
- **SHUTDOWN SAFE**: Rejects shutdown in unsafe situations.
- **Dynamic I/O threads**: `io-threads` can be modified at runtime.
- **Un-deprecation**: 25 previously deprecated commands are now un-deprecated.

**Behavior changes**:
- Auth check moved before command existence/arity/protected checks
- Error messages in MULTI/EXEC include the full command name
- `STALE` flag added to `SCRIPT EXISTS`, `SCRIPT SHOW`, `SCRIPT FLUSH`

**Known critical bugs in early 9.0 releases**:
- 9.0.0-9.0.2: Multiple hash field expiration bugs (memory leaks, crashes, data corruption)
- 9.0.0: Crash when aborting slot migration while child snapshot is active
- 9.0.0: Lua VM crash after `FUNCTION FLUSH ASYNC` + `FUNCTION LOAD`
- 9.0.1: Deadlock in IO-thread shutdown during panic
- **Recommendation**: Use Valkey 9.0.3+ which includes all critical fixes

### RDB Format Compatibility

- Valkey 8.x RDB files are compatible with Redis 7.2.x
- Valkey 9.0 RDB files include new data types (hash field expiration metadata) and may not be loadable by 8.x or Redis 7.x
- 9.0-rc2 included "relaxed RDB check for foreign RDB formats" to ease migration

---

## Configuration Compatibility: Redis 7.x vs Valkey 8.x/9.x

### Identical Configuration Parameters

Valkey 8.x accepts all Redis 7.2.x configuration parameters. You can use your existing `redis.conf` by:

1. Renaming it to `valkey.conf` (optional - Valkey reads any named config file)
2. Updating binary paths (`redis-server` to `valkey-server`)
3. Updating CLI references (`redis-cli` to `valkey-cli`)

### Renamed Parameters (Aliases Maintained)

Valkey maintains backward-compatible aliases for Redis-era config names:

| Redis Name | Valkey Name | Status |
|------------|-------------|--------|
| `slaveof` | `replicaof` | Both work (alias since Redis 5.0) |
| `masterauth` | `primaryauth` | Both work |
| `slave-read-only` | `replica-read-only` | Both work |
| `slave-lazy-flush` | `replica-lazy-flush` | Both work |
| `min-slaves-to-write` | `min-replicas-to-write` | Both work |
| `min-slaves-max-lag` | `min-replicas-max-lag` | Both work |

### New Configuration Parameters in Valkey

**Valkey 8.0**:
- `repl-backlog-size` default changed to 10 MB (was 1 MB)
- Dual-channel replication parameters
- I/O threads enhancements

**Valkey 8.1**:
- `cluster-manual-failover-timeout`
- `hide-user-data-from-log`

**Valkey 9.0**:
- `cluster-announce-client-(port|tls-port)`
- Auto-failover on shutdown config
- Dynamic `io-threads` modification
- Hash field expiration related internals

### Environment Variables

| Variable | Support |
|----------|---------|
| `REDISCLI_AUTH` | Supported (legacy) |
| `VALKEYCLI_AUTH` | Supported (new in 9.0) |
| `REDISCLI_CLUSTER_YES` | Supported |

---

## Data Validation After Migration

### Automated Validation Steps

#### 1. Key Count Comparison

```bash
# On source (Redis/old Valkey)
redis-cli -h <source> INFO keyspace

# On target (new Valkey)
valkey-cli -h <target> INFO keyspace

# Compare db0:keys=<count> values
```

#### 2. Memory Usage Comparison

```bash
valkey-cli -h <source> INFO memory | grep used_memory_human
valkey-cli -h <target> INFO memory | grep used_memory_human
```

Memory may differ slightly due to different allocator states, but should be within ~10%.

#### 3. Spot-Check Key Values

```bash
# Sample random keys
valkey-cli -h <target> RANDOMKEY
# Compare value with source
valkey-cli -h <source> GET <key>
valkey-cli -h <target> GET <key>
```

#### 4. TTL Validation

```bash
# Check that TTLs transferred correctly
valkey-cli -h <target> RANDOMKEY
valkey-cli -h <target> TTL <key>
valkey-cli -h <source> TTL <key>
# TTLs should be close (within a few seconds)
```

#### 5. Data Type Verification

```bash
# For each data type, verify a sample
valkey-cli -h <target> TYPE <key>
valkey-cli -h <target> OBJECT ENCODING <key>
```

#### 6. Replication Offset Verification

During replication-based migration, before promoting:

```bash
# On primary
valkey-cli -h <primary> INFO replication | grep master_repl_offset

# On replica
valkey-cli -h <replica> INFO replication | grep master_repl_offset

# Offsets should match
```

#### 7. Cluster Health Check

```bash
valkey-cli --cluster check <any-node>:<port>
# Should report: [OK] All 16384 slots covered
# No errors about key counts or slot assignments
```

#### 8. Consistency Testing (Extended)

The Valkey repository includes `consistency-test.rb` for cluster environments. It uses counters with `INCR` and detects lost writes or phantom writes. For production migrations:

```bash
# Run the consistency test against the new cluster
ruby consistency-test.rb
# Monitor for "lost" or "inconsistency" messages
```

#### 9. Application-Level Validation

- Run application test suites against the new Valkey instance
- Compare response latencies (P50, P99, P999)
- Monitor error rates during and after migration
- Check `INFO commandstats` for unexpected command failures

---

## Rollback Procedures

### Standalone Rollback

**If using replication-based migration** (old primary still running):

1. Redirect clients back to the old primary
2. Stop the new Valkey instance
3. The old primary should still have all data (it was only paused, not shut down)

**If old primary was shut down**:

1. Ensure you kept the old RDB/AOF files
2. Restart the old Redis/Valkey instance with the preserved data files
3. Redirect clients back

### Cluster Rollback

**During rolling upgrade** (partially complete):

1. Stop the upgrade process (don't upgrade remaining shards)
2. For shards already upgraded: perform manual failover back to old replicas (if still running)
   ```bash
   valkey-cli -h <old-replica> -p <port> CLUSTER FAILOVER
   ```
3. Remove the new nodes: `valkey-cli --cluster del-node`

**After complete upgrade**:

- If old nodes were kept as replicas, perform manual failover back to them
- If old nodes were decommissioned, restore from backup/RDB and rebuild the cluster

### Sentinel Rollback

1. Trigger manual failover back to an old-version replica (if still available):
   ```bash
   valkey-cli -p 26379 SENTINEL FAILOVER <master-name>
   ```
2. Downgrade Sentinel binaries in reverse order

### Pre-Rollback Checklist

Before any upgrade, ensure:
- [ ] RDB/AOF backups from before the upgrade
- [ ] Old binaries preserved
- [ ] Old configuration files preserved
- [ ] Document the current cluster topology (`CLUSTER NODES` output)
- [ ] Test rollback procedure in staging

---

## Pitfalls and Gotchas from Real Deployments

### Binary and Path Changes

- **Binary names changed**: `redis-server` to `valkey-server`, `redis-cli` to `valkey-cli`, `redis-sentinel` to `valkey-sentinel`, `redis-benchmark` to `valkey-benchmark`, `redis-check-aof` to `valkey-check-aof`, `redis-check-rdb` to `valkey-check-rdb`
- **Systemd units**: Update service files to reference new binary names
- **Monitoring tools**: Update any monitoring that checks process names (e.g., `pgrep redis-server`)
- **Scripts**: Audit all operational scripts for hardcoded Redis binary names

### Configuration File Gotchas

- Valkey reads `redis.conf` directives but the default config file is named `valkey.conf`
- The `LOLWUT` output changed from "Redis ver." to "Valkey ver." in 9.0 (may break naive version detection scripts)
- Default `repl-backlog-size` changed from 1 MB to 10 MB in 8.0 RC2 - may affect memory planning

### Replication During Upgrade

- **Primary persistence critical**: If a primary without persistence restarts, it comes up empty. All replicas sync with it and lose their data. Either enable persistence or disable auto-restart.
- **Avoid writable replicas during upgrade**: Do not configure an instance as a writable replica as an intermediary step.
- **Partial resync requires clean shutdown**: Use `SHUTDOWN` command (not `kill -9`) to store replication info in RDB for partial resync on restart.
- **AOF incompatibility with partial resync**: Cannot partially resync a replica that restarted via AOF. Convert to RDB before shutdown if needed.
- **Diskless replication for EC2/EBS**: EBS volumes can have high latency. Use `repl-diskless-sync yes` to avoid disk I/O during sync.

### Cluster-Specific Gotchas

- **Stale gossip packets**: Fixed in 8.0.3+ and 8.1.1+. In mixed-version clusters during upgrade, stale gossip packets arriving out of order were previously accepted.
- **Divergent shard-id**: If a replica's shard-id in `nodes.conf` diverges from the primary, it's now reconciled to the primary's shard-id (8.0.5+). This could cause unexpected behavior during upgrades of older versions.
- **CLUSTER SLOTS/NODES incorrect after port change**: Fixed in 8.0.5+. If you change `port` or `tls-port` via CONFIG during upgrade, the cluster info could be stale.
- **Replica failover stall**: Replicas could stall failover due to outdated config epoch (fixed 8.0.5+). Upgrade to 8.0.5+ first if running older 8.0.x.

### Valkey 9.0 Specific Gotchas

- **Hash field expiration bugs**: 9.0.0-9.0.1 had multiple critical bugs including memory leaks, crashes, and data corruption related to hash field expiration. **Use 9.0.3+ in production.**
- **HSETEX case sensitivity**: `FNX` and `FXX` arguments were case-sensitive in 9.0.0-9.0.1 (fixed in 9.0.2).
- **Module ASM opt-in**: Modules must explicitly opt in to Atomic Slot Migration. If not opted in, ASM is disabled cluster-wide. Check all loaded modules before upgrading.
- **COMMANDLOG performance regression**: 9.0.1 introduced a performance regression when `commandlog-reply-larger-than` is set to -1. Mitigated in 9.0.2.
- **Slot cache optimization**: Can cause "key duplication and data corruption" with AOF clients (fixed 9.0.2).

### Client Library Compatibility

- Redis client libraries work with Valkey 8.x without changes
- For Valkey 9.0 features, check if your client library supports the new commands
- `REDISCLI_AUTH` still works but `VALKEYCLI_AUTH` is preferred
- Valkey 9.0 defaults changed for `valkey-cli` to use Valkey naming, with fallback to old values

### TLS Gotchas

- 8.0.2: Fixed uncommon crash using TLS with dual channel replication
- 8.0.5: Fixed `SSL_new()` returning NULL for outgoing TLS connections
- 8.0.5: Fixed "SSL routines::bad length" error on repeated TLS writes
- 8.1.0 RC2: Fixed replica disconnecting when using TLS
- 9.0-rc1: Fixed crash during TLS handshake with I/O threads

---

## Downtime Estimates by Method

| Method | Topology | Downtime Estimate | Notes |
|--------|----------|-------------------|-------|
| Replication + failover | Standalone | Seconds | Client switchover window only |
| RDB snapshot restore | Standalone | Minutes to hours | Depends on dataset size |
| AOF replay | Standalone | Minutes to hours | Depends on AOF file size |
| Rolling upgrade | Cluster | Zero (per-shard seconds) | Each shard has a brief failover |
| Sentinel failover | Sentinel | 1-5 seconds | Automatic failover handles promotion |
| Helm migration (Bitnami to Official) | Kubernetes | Brief maintenance window | Replication + FAILOVER command |
| ElastiCache RDB export | Managed to self-hosted | 30-60+ minutes | Snapshot + download + load |
| ElastiCache replication | Managed to self-hosted | Seconds | If network allows replication |
| Dual-write | Any | Zero | Requires application changes |

### Factors Affecting Downtime

- **Dataset size**: Larger datasets take longer for initial sync, RDB save/load
- **Network bandwidth**: Cross-region or cross-cloud transfers are slower
- **Memory**: Need 2x memory during replication-based migration (two instances)
- **Write rate**: Higher write rates make it harder for replicas to catch up
- **TLS**: TLS adds overhead to replication sync
- **Disk speed**: RDB save/load and AOF replay are I/O bound (use `repl-diskless-sync` to avoid)

---

## Operational Lessons from Large-Scale Deployments

Source: Valkey blog "Operational Lessons from Large-Scale Valkey Deployments" (2026-02-19), reporting from the Unlocked Conference.

### Key Insights

#### Scale Changes the Nature of Problems

> "Scale exposes all truths." - Khawaja Shams

- Latency that feels negligible at small scale becomes visible at large scale
- Client behavior that looked harmless shapes tail latencies
- Operational shortcuts introduce instability at higher workloads
- The question shifts from "does it work?" to "what happens when it's stressed?"

#### Predictability Over Peak Throughput

The Valkey project's five guiding performance principles list "provide predictable user latency" as second priority. Focus on:

- P99 and P999 latency, not just medians
- A large gap between P99 and P999 reveals instability
- Outages come from edge cases, not the happy path
- Multi-megabyte values distort tail percentiles even when average latency looks stable

#### Payload Size and Bandwidth Shape Outcomes

From Mercado Libre's experience:

> "Nodes dying because of the volume of bytes moving in and out was the hardest problem to solve."

- Bandwidth becomes a primary bottleneck before CPU/memory metrics indicate trouble
- Monitor payload size distribution, not just request counts
- Network throughput and payload variability dominate behavior before standard utilization metrics signal trouble

### Recommendations for Migration Operations

1. **Monitor P99 and P999 latency** during and after migration - tail percentiles reveal issues while medians look stable
2. **Instrument payload size distribution** alongside traditional metrics
3. **Treat traffic shape as a first-class metric** - bursty workloads and large responses explain instability better than raw request counts
4. **Test under production-like load** before cutover
5. **Use CLIENT PAUSE** during switchover to prevent split-brain writes

---

## Sources

### Official Documentation
- Valkey Administration: https://valkey.io/topics/admin/
- Valkey Cluster Tutorial: https://valkey.io/topics/cluster-tutorial/
- Valkey Cluster Specification: https://valkey.io/topics/cluster-spec/
- Valkey Replication: https://valkey.io/topics/replication/
- Valkey Sentinel: https://valkey.io/topics/sentinel/

### Release Notes
- Valkey 8.0 Release Notes: https://github.com/valkey-io/valkey/blob/8.0/00-RELEASENOTES
- Valkey 8.1 Release Notes: https://github.com/valkey-io/valkey/blob/8.1/00-RELEASENOTES
- Valkey 9.0 Release Notes: https://github.com/valkey-io/valkey/blob/9.0/00-RELEASENOTES

### Blog Posts
- "Valkey 9.0: innovation, features, and improvements" (2025-10-21): https://valkey.io/blog/introducing-valkey-9/
- "Operational Lessons from Large-Scale Valkey Deployments" (2026-02-19): https://valkey.io/blog/operational-lessons/
- "Valkey Helm: The new way to deploy Valkey on Kubernetes" (2026-01-06): https://valkey.io/blog/valkey-helm-chart/
- "Resharding, Reimagined: Introducing Atomic Slot Migration" (2025-10-29): https://valkey.io/blog/atomic-slot-migration/
- "Scaling a Valkey Cluster to 1 Billion Request per Second" (2025-10-20): https://valkey.io/blog/1-billion-rps/
- "How Valkey 8.1 Handles 50 Million Sorted Set Inserts" (2025-10-02): https://valkey.io/blog/50-million-zsets/
- "Upgrade Stories from the Community, Volume 1" (2025-05-14): https://valkey.io/blog/ (upgrade-stories)
- "Valkey 8.1: Continuing to Deliver Enhanced Performance and Reliability" (2025-04-02): https://valkey.io/blog/ (valkey-8-1)

### GitHub
- Valkey Repository: https://github.com/valkey-io/valkey
- Valkey Helm Chart: https://github.com/valkey-io/valkey-helm
