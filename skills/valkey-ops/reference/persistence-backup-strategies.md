# Backup Strategies

Use when implementing automated backup strategies for Valkey - RDB snapshot scripts, AOF backup procedures, off-site backup, or replica-based backup.

## Contents

- Backup Methods Overview (line 17)
- Automated RDB Backup Script (line 26)
- AOF Backup Procedure (line 92)
- Off-Site Backup (line 143)
- Replica-Based Backup (line 184)
- Retention Strategy (line 201)

---

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
alerting if backup transfers fail.

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

## Retention Strategy

| Tier | Frequency | Retention | Storage |
|------|-----------|-----------|---------|
| Hourly | Every hour | 24 hours | Local disk |
| Daily | Once per day | 30 days | Local + off-site |
| Weekly | Once per week | 90 days | Off-site only |
| Monthly | First of month | 1 year | Off-site cold storage |

Adjust based on your data volume and compliance requirements.

---

## See Also

- [disaster-recovery](disaster-recovery.md) - Recovery procedures, FLUSHALL recovery, verification
- [rdb](rdb.md) - RDB configuration
- [aof](aof.md) - AOF configuration
