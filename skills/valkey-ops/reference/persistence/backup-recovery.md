# Backup and Disaster Recovery

Use when implementing automated backup strategies, planning disaster recovery procedures, or performing point-in-time recovery from RDB or AOF files.

## Contents

- When to Use This Guide (line 21)
- Backup Methods Overview (line 28)
- Automated RDB Backup Script (line 37)
- AOF Backup Procedure (line 103)
- Off-Site Backup (line 154)
- Replica-Based Backup (line 195)
- Disaster Recovery Procedures (line 214)
- Recovery Time Estimates (line 282)
- Backup Verification (line 299)
- Retention Strategy (line 339)
- See Also (line 350)

---

## When to Use This Guide

- Setting up automated backups for production Valkey
- Planning off-site backup and retention policies
- Recovering from data loss, corruption, or accidental commands
- Performing point-in-time recovery or data migration between environments

## Backup Methods Overview

| Method | What It Captures | Data Loss Window | Complexity |
|--------|-----------------|------------------|------------|
| RDB snapshot copy | Full dataset at snapshot time | Since last BGSAVE | Low |
| AOF directory copy | All writes up to last fsync | ~1 second (with `everysec`) | Medium |
| Replica-based backup | Full dataset, zero primary impact | Replication lag | Higher |
| RDB + AOF combined | Full dataset + recent writes | Minimal | Medium |

## Automated RDB Backup Script

```bash
#!/bin/bash
# valkey-backup.sh - RDB snapshot backup with retention
set -euo pipefail

VALKEY_CLI="valkey-cli -a ${VALKEY_PASSWORD}"
DATA_DIR="/var/lib/valkey"
BACKUP_DIR="/backups/valkey"
DATE=$(date +%Y%m%d_%H%M%S)
RETENTION_DAYS=30

# Trigger fresh snapshot
${VALKEY_CLI} BGSAVE

# Wait for BGSAVE to complete
PREV=$(${VALKEY_CLI} LASTSAVE)
TIMEOUT=300
ELAPSED=0
while [ "$(${VALKEY_CLI} LASTSAVE)" = "$PREV" ]; do
  sleep 2
  ELAPSED=$((ELAPSED + 2))
  if [ $ELAPSED -ge $TIMEOUT ]; then
    echo "[ERROR] BGSAVE did not complete within ${TIMEOUT}s"
    exit 1
  fi
done

# Verify BGSAVE succeeded
STATUS=$(${VALKEY_CLI} INFO persistence | grep rdb_last_bgsave_status | tr -d '\r')
if [[ "$STATUS" != *"ok"* ]]; then
  echo "[ERROR] BGSAVE failed: $STATUS"
  exit 1
fi

# Copy RDB file
mkdir -p "$BACKUP_DIR"
cp "${DATA_DIR}/dump.rdb" "${BACKUP_DIR}/dump_${DATE}.rdb"

# Generate checksum
sha256sum "${BACKUP_DIR}/dump_${DATE}.rdb" > "${BACKUP_DIR}/dump_${DATE}.rdb.sha256"

# Verify copy integrity
if ! sha256sum -c "${BACKUP_DIR}/dump_${DATE}.rdb.sha256" --quiet; then
  echo "[ERROR] Backup checksum verification failed"
  exit 1
fi

echo "[OK] Backup created: dump_${DATE}.rdb ($(du -h "${BACKUP_DIR}/dump_${DATE}.rdb" | cut -f1))"

# Retention: delete backups older than $RETENTION_DAYS days
find "$BACKUP_DIR" -name "dump_*.rdb" -mtime +${RETENTION_DAYS} -delete
find "$BACKUP_DIR" -name "dump_*.sha256" -mtime +${RETENTION_DAYS} -delete

echo "[OK] Retention applied: kept last ${RETENTION_DAYS} days"
```

### Cron Schedule

```bash
# /etc/cron.d/valkey-backup
# Hourly RDB backups
0 * * * * valkey /opt/scripts/valkey-backup.sh >> /var/log/valkey/backup.log 2>&1
```

## AOF Backup Procedure

AOF backups require temporarily pausing auto-rewrite to avoid file changes
mid-copy. The hardlink optimization minimizes the rewrite-disabled window.

### Hardlink-Based AOF Backup (Recommended)

Valkey guarantees it only appends to files in the AOF directory or
completely replaces them. This makes hardlinks safe for consistent backup.

```bash
#!/bin/bash
# valkey-backup-aof.sh - AOF backup using hardlinks for minimal disabled window
set -euo pipefail

VALKEY_CLI="valkey-cli -a ${VALKEY_PASSWORD}"
DATA_DIR="/var/lib/valkey"
BACKUP_DIR="/backups/valkey/aof"
DATE=$(date +%Y%m%d_%H%M%S)
LINK_DIR="${BACKUP_DIR}/${DATE}-links"

# Save current percentage for restore
PREV_PCT=$(${VALKEY_CLI} CONFIG GET auto-aof-rewrite-percentage | tail -1)
${VALKEY_CLI} CONFIG SET auto-aof-rewrite-percentage 0

# Wait for any in-progress rewrite to finish
while [ "$(${VALKEY_CLI} INFO persistence | grep aof_rewrite_in_progress | tr -d '\r' | cut -d: -f2)" != "0" ]; do
  sleep 1
done

# Create hardlinks (near-instant regardless of file size)
mkdir -p "$LINK_DIR"
cp -al "${DATA_DIR}/appendonlydir/" "$LINK_DIR/"

# Re-enable auto-rewrite immediately
${VALKEY_CLI} CONFIG SET auto-aof-rewrite-percentage "${PREV_PCT}"

# Compress from hardlinks at leisure
tar czf "${BACKUP_DIR}/${DATE}.tar.gz" -C "$LINK_DIR" appendonlydir/
rm -rf "$LINK_DIR"

echo "[OK] AOF backup: ${BACKUP_DIR}/${DATE}.tar.gz"

# Retention
find "$BACKUP_DIR" -name "*.tar.gz" -mtime +7 -delete
```

To make this restart-safe (if the server restarts during backup), add
`CONFIG REWRITE` after disabling auto-rewrite, then again after
re-enabling it.

## Off-Site Backup

### S3 Upload with Encryption and Verification

```bash
# Compress, upload with SSE, verify size
gzip "${BACKUP_DIR}/dump_${DATE}.rdb"
aws s3 cp "${BACKUP_DIR}/dump_${DATE}.rdb.gz" \
  "s3://valkey-backups/${HOSTNAME}/$(date +%Y/%m)/" \
  --sse AES256 \
  --storage-class STANDARD_IA
aws s3 cp "${BACKUP_DIR}/dump_${DATE}.rdb.sha256" \
  "s3://valkey-backups/${HOSTNAME}/$(date +%Y/%m)/" \
  --sse AES256 \
  --storage-class STANDARD_IA
```

S3 lifecycle policy for tiered retention: transition to GLACIER_IR at 30
days, DEEP_ARCHIVE at 90 days, expire at 365 days.

### GCS Upload

```bash
gsutil -o "GSUtil:parallel_composite_upload_threshold=150M" \
  cp "${BACKUP_DIR}/dump_${DATE}.rdb.gz" \
  "gs://valkey-backups/${HOSTNAME}/$(date +%Y/%m)/"
```

GCS lifecycle: transition to NEARLINE at 30 days, COLDLINE at 90 days,
delete at 365 days.

### Cross-Region SCP

```bash
scp "${BACKUP_DIR}/dump_${DATE}.rdb" \
  backup-user@dr-host:/backups/valkey/
```

Always verify upload size matches local file size and set up independent
alerting if backup transfers fail (official recommendation).

## Replica-Based Backup

Use a dedicated replica for backups to avoid fork overhead on the primary.

```bash
# On the backup replica
valkey-cli -h backup-replica -p 6379 BGSAVE

# Wait, then copy from the replica's data directory
# The primary is never affected
```

Configure the backup replica with:

```
replicaof primary-host 6379
replica-priority 0          # never promote this replica
```

## Disaster Recovery Procedures

### Recover from RDB

1. Stop the Valkey server
2. Copy the backup RDB to the data directory with the correct filename
3. Start the server

```bash
sudo systemctl stop valkey
cp /backups/valkey/dump_20260329_120000.rdb /var/lib/valkey/dump.rdb
chown valkey:valkey /var/lib/valkey/dump.rdb
sudo systemctl start valkey

# Verify
valkey-cli DBSIZE
valkey-cli INFO keyspace
```

### Recover from AOF

1. Stop the server
2. Replace the entire `appendonlydir` with the backup
3. Start the server

```bash
sudo systemctl stop valkey
rm -rf /var/lib/valkey/appendonlydir
cp -r /backups/valkey/aof/20260329_120000/appendonlydir /var/lib/valkey/
chown -R valkey:valkey /var/lib/valkey/appendonlydir
sudo systemctl start valkey
```

When both RDB and AOF exist, Valkey loads AOF (it is more complete).

### Recover from Accidental FLUSHALL

If AOF is enabled and FLUSHALL was just executed:

1. **Stop the server immediately** - do not let it rewrite the AOF
2. Edit the last `.incr.aof` file in `appendonlydir/`
3. Remove the `FLUSHALL` command (it will be near the end)
4. Start the server

```bash
sudo systemctl stop valkey

# Find and edit the latest incremental file
LATEST=$(ls -t /var/lib/valkey/appendonlydir/*.incr.aof | head -1)
# Remove the FLUSHALL line (last occurrence)
sed -i '/FLUSHALL/d' "$LATEST"

sudo systemctl start valkey
valkey-cli DBSIZE
```

### Point-in-Time Recovery

AOF with timestamps (`aof-timestamp-enabled yes`) enables point-in-time recovery:

```bash
# Truncate AOF to a specific timestamp
valkey-check-aof --truncate-to-timestamp 1711699200 \
  appendonlydir/appendonly.aof.manifest
```

Without timestamps, you can only recover to the last AOF rewrite boundary or the end of the file.

## Recovery Time Estimates

RDB restore time depends primarily on file size and disk speed:

| Dataset Size | RDB File (compressed) | Load Time (SSD) | Load Time (HDD) |
|-------------|----------------------|-----------------|-----------------|
| 1 GB | ~400 MB | 2-5 seconds | 5-15 seconds |
| 5 GB | ~2 GB | 10-20 seconds | 30-60 seconds |
| 10 GB | ~4 GB | 20-40 seconds | 60-120 seconds |
| 25 GB | ~10 GB | 45-90 seconds | 2-5 minutes |
| 50 GB | ~20 GB | 90-180 seconds | 5-10 minutes |
| 100 GB | ~40 GB | 3-6 minutes | 10-20 minutes |

AOF restore is slower because commands must be replayed. With
`aof-use-rdb-preamble yes` (hybrid), load times approach RDB since the
base is in RDB format.

## Backup Verification

Backups are worthless if you never test restores.

### Automated Verification

```bash
#!/bin/bash
# valkey-verify-backup.sh - test restore in isolated instance
set -euo pipefail

BACKUP_RDB="$1"
TEST_PORT=6399

# Start temporary instance with the backup
valkey-server --port $TEST_PORT --dir /tmp/valkey-verify \
  --dbfilename "$(basename "$BACKUP_RDB")" --daemonize yes

sleep 2

# Check it loaded
KEYS=$(valkey-cli -p $TEST_PORT DBSIZE | awk '{print $2}')
if [ "$KEYS" -gt 0 ]; then
  echo "[OK] Backup verified: $KEYS keys loaded"
else
  echo "[ERROR] Backup appears empty or corrupt"
fi

valkey-cli -p $TEST_PORT SHUTDOWN NOSAVE
rm -rf /tmp/valkey-verify
```

### Verification Checklist

- [ ] RDB file checksum matches (sha256)
- [ ] File size is within expected range (not zero, not dramatically smaller)
- [ ] Test restore loads expected key count
- [ ] Test restore completes without errors in the log
- [ ] Off-site copies are accessible and match local checksums

## Retention Strategy

| Tier | Frequency | Retention | Storage |
|------|-----------|-----------|---------|
| Hourly | Every hour | 24 hours | Local disk |
| Daily | Once per day | 30 days | Local + off-site |
| Weekly | Once per week | 90 days | Off-site only |
| Monthly | First of month | 1 year | Off-site cold storage |

Adjust based on your data volume and compliance requirements.

## See Also

- [RDB Persistence](rdb.md) - snapshot configuration details
- [AOF Persistence](aof.md) - write-ahead log configuration
- [Durability vs Performance](../performance/durability.md) - persistence trade-off spectrum
- [Replication Setup](../replication/setup.md) - primary-replica configuration for replica-based backups
- [Replication Safety](../replication/safety.md) - replica-based backup strategy and write safety
- [Capacity Planning](../operations/capacity-planning.md) - memory sizing for fork overhead
- [Production Checklist](../production-checklist.md) - backup verification checklist
