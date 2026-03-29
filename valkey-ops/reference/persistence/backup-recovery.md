# Backup and Disaster Recovery

Use when implementing automated backup strategies, planning disaster recovery procedures, or performing point-in-time recovery from RDB or AOF files.

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

AOF backups require temporarily pausing auto-rewrite to avoid file changes mid-copy.

```bash
#!/bin/bash
# valkey-backup-aof.sh - AOF directory backup
set -euo pipefail

VALKEY_CLI="valkey-cli -a ${VALKEY_PASSWORD}"
DATA_DIR="/var/lib/valkey"
BACKUP_DIR="/backups/valkey/aof"
DATE=$(date +%Y%m%d_%H%M%S)

# Pause auto-rewrite during copy
${VALKEY_CLI} CONFIG SET auto-aof-rewrite-percentage 0

# Copy entire AOF directory atomically
mkdir -p "${BACKUP_DIR}/${DATE}"
cp -r "${DATA_DIR}/appendonlydir" "${BACKUP_DIR}/${DATE}/"

# Re-enable auto-rewrite
${VALKEY_CLI} CONFIG SET auto-aof-rewrite-percentage 100

echo "[OK] AOF backup created: ${BACKUP_DIR}/${DATE}"

# Retention
find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -mtime +7 -exec rm -rf {} +
```

## Off-Site Backup

### S3/GCS Upload

```bash
# After local backup completes
aws s3 cp "${BACKUP_DIR}/dump_${DATE}.rdb" \
  "s3://valkey-backups/${HOSTNAME}/" \
  --sse AES256 \
  --storage-class STANDARD_IA

# Or GCS
gsutil cp "${BACKUP_DIR}/dump_${DATE}.rdb" \
  "gs://valkey-backups/${HOSTNAME}/"
```

### Cross-Region SCP

```bash
scp "${BACKUP_DIR}/dump_${DATE}.rdb" \
  backup-user@dr-host:/backups/valkey/
```

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
- [Replication Safety](../replication/safety.md) - replica-based backup strategy
- [Production Checklist](../production-checklist.md) - backup verification checklist
