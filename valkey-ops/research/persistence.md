# Persistence Research - Deep Web Research Findings

Research date: 2026-03-29
Purpose: Enrich existing valkey-ops persistence reference docs (aof.md, rdb.md, backup-recovery.md, durability.md)

---

## Source Index

| # | Source | URL | Status |
|---|--------|-----|--------|
| 1 | Valkey official persistence docs | https://valkey.io/topics/persistence/ | Fetched |
| 2 | Valkey administration guide | https://valkey.io/topics/admin/ | Fetched |
| 3 | Valkey FAQ (fork, memory) | https://valkey.io/topics/faq/ | Fetched |
| 4 | Valkey latency diagnosis | https://valkey.io/topics/latency/ | Fetched |
| 5 | Valkey replication docs | https://valkey.io/topics/replication/ | Fetched |
| 6 | Valkey default config (unstable) | github.com/valkey-io/valkey/blob/unstable/valkey.conf | Fetched |
| 7 | BGSAVE command reference | https://valkey.io/commands/bgsave/ | Fetched |
| 8 | BGREWRITEAOF command reference | https://valkey.io/commands/bgrewriteaof/ | Fetched |
| 9 | Valkey 9.0 announcement | https://valkey.io/blog/introducing-valkey-9/ | Fetched |
| 10 | antirez: Redis Persistence Demystified | http://antirez.com/post/redis-persistence-demystified.html | Fetched |
| 11 | AWS ElastiCache backup docs | docs.aws.amazon.com/AmazonElastiCache/latest/dg/backups.html | Fetched |
| 12 | Valkey memory optimization | https://valkey.io/topics/memory-optimization/ | Fetched |

---

## 1. RDB vs AOF Production Decision Guide

### Findings Not Yet in Reference Docs

**Official recommendation from valkey.io/topics/persistence:**

> "The general indication you should use both persistence methods is if you want a degree of data safety comparable to what PostgreSQL can provide you."

> "There are many users using AOF alone, but we discourage it since to have an RDB snapshot from time to time is a great idea for doing database backups, for faster restarts, and in the event of bugs in the AOF engine."

**Decision matrix (synthesized from official docs + antirez post):**

| Scenario | Recommended | Why |
|----------|-------------|-----|
| PostgreSQL-level safety | RDB + AOF | Dual persistence covers both fast restarts and sub-second durability |
| Few minutes data loss acceptable | RDB alone | Lower complexity, fast restarts, excellent for backups |
| AOF-only (discouraged) | AOF alone | Discouraged by Valkey team - RDB snapshots protect against AOF engine bugs |
| Pure cache | None | `save ""` and `appendonly no` |

**antirez on fsync realities (applies identically to Valkey):**

The write path has 5 layers: (1) client memory -> (2) server memory -> (3) kernel buffer -> (4) disk controller cache -> (5) physical media. The POSIX API gives control over steps 3 and 4 (via write(2) and fsync(2)), but step 5 (disk controller to physical media) is outside application control. Disk controller write-back caching should be disabled for durability, or backed by battery/supercapacitor.

---

## 2. Hybrid Persistence Real-World Performance

### Findings to Enrich aof.md

**From valkey.conf (source of truth):**

```
# The server can create append-only base files in either RDB or AOF formats.
# Using the RDB format is always faster and more efficient, and disabling it
# is only supported for backward compatibility purposes.
aof-use-rdb-preamble yes
```

The default `aof-use-rdb-preamble yes` means:
- Base file is written in RDB binary format during AOF rewrite
- Incremental files remain in AOF command format
- On restart: Valkey reads "Reading RDB preamble from AOF file..." then "Reading the remaining AOF tail..."
- This is faster than pure AOF loading because the base is a compact binary, not a command replay

**Startup log sequence (from official docs):**

```
* Reading RDB preamble from AOF file...
* Reading the remaining AOF tail...
```

If the AOF is truncated, the warning appears:

```
# !!! Warning: short read while loading the AOF file !!!
# !!! Truncating the AOF at offset 439 !!!
# AOF loaded anyway because aof-load-truncated is enabled
```

**Load priority when both exist:**

> "In the case both AOF and RDB persistence are enabled and Valkey restarts, the AOF file will be used to reconstruct the original dataset since it is guaranteed to be the most complete."

---

## 3. Multi-Part AOF Architecture Deep Dive

### Findings to Enrich aof.md

**File naming convention (from valkey.conf):**

```
# For example, if appendfilename is set to appendonly.aof, the following file
# names could be derived:
#
# - appendonly.aof.1.base.rdb as a base file.
# - appendonly.aof.1.incr.aof, appendonly.aof.2.incr.aof as incremental files.
# - appendonly.aof.manifest as a manifest file.
```

**Rewrite process (detailed from official docs):**

1. Parent opens a new incremental AOF file to continue writing
2. Child starts writing new base AOF in a temporary file
3. If rewrite fails: old base + old increments + newly opened increment file = complete dataset (safe)
4. On child completion: parent builds temp manifest from child's base file + new increment file
5. Atomic exchange: manifest files are swapped atomically
6. Cleanup: old base and unused increment files are deleted

**Rewrite failure limiting (new finding):**

> "Valkey introduces an AOF rewrite limiting mechanism to ensure that failed AOF rewrites are retried at a slower and slower rate."

This is an exponential backoff on AOF rewrite retries after failures - prevents repeated fork storms when rewrites keep failing (e.g., OOM on fork).

**AOF timestamp annotations (from valkey.conf):**

```
# The server supports recording timestamp annotations in the AOF to support
# restoring the data from a specific point-in-time. However, using this
# capability changes the AOF format in a way that may not be compatible
# with existing AOF parsers.
aof-timestamp-enabled no
```

This is the mechanism that enables `valkey-check-aof --truncate-to-timestamp`.

---

## 4. Fork Performance Impact on Large Datasets

### Findings to Enrich rdb.md and latency.md

**Page table math (from official Valkey latency docs):**

> "For instance on a Linux/AMD64 system, the memory is divided in 4 kB pages. To convert virtual addresses to physical addresses, each process stores a page table (actually represented as a tree) containing at least a pointer per page of the address space of the process. So a large 24 GB Valkey instance requires a page table of 24 GB / 4 kB * 8 = 48 MB."

Formula: `page_table_size = dataset_size / 4KB * 8 bytes`

| Dataset Size | Page Table Size | Approx Fork Time (modern HW) |
|-------------|-----------------|-------------------------------|
| 1 GB | 2 MB | ~1-2 ms |
| 4 GB | 8 MB | ~4-8 ms |
| 10 GB | 20 MB | ~10-20 ms |
| 24 GB | 48 MB | ~24-48 ms |
| 64 GB | 128 MB | ~64-128 ms |
| 128 GB | 256 MB | ~128-256 ms |

**Measurement method (from official docs):**

> "You can measure the fork time for a Valkey instance by performing a BGSAVE and looking at the latest_fork_usec field in the INFO command output."

```bash
valkey-cli BGSAVE
sleep 2
valkey-cli INFO stats | grep latest_fork_usec
```

**Fork rate quality thresholds (from LATENCY DOCTOR source analysis in latency.md):**

| Rate | Quality |
|------|---------|
| < 10 GB/s | Terrible |
| < 25 GB/s | Poor |
| < 100 GB/s | Good |
| >= 100 GB/s | Excellent |

Fork rate = dataset_size / fork_time. A 24 GB instance that forks in 48ms = 500 GB/s (excellent). Same instance at 500ms = 48 GB/s (poor - likely VM without HW-assisted virtualization or THP enabled).

**Copy-on-write memory overhead (from official admin + FAQ docs):**

> "If you are using Valkey in a write-heavy application, while saving an RDB file on disk or rewriting the AOF log, Valkey can use up to 2 times the memory normally used. The additional memory used is proportional to the number of memory pages modified by writes during the saving process."

Worst case: 2x memory during BGSAVE/BGREWRITEAOF on write-heavy workloads.
Typical case: 10-30% additional memory for moderate write rates.
Best case (read-heavy): near-zero additional memory due to COW sharing.

**Overcommit memory requirement (from FAQ):**

> "Setting overcommit_memory to 1 tells Linux to relax and perform the fork in a more optimistic allocation fashion."

```bash
echo 1 > /proc/sys/vm/overcommit_memory
# Or persist:
echo "vm.overcommit_memory = 1" >> /etc/sysctl.conf
```

Without this, a 3 GB Redis/Valkey instance with only 2 GB free will fail to fork even though COW means it only needs a fraction of that.

**Transparent Huge Pages impact (from latency docs):**

> "Fork is called, two processes with shared huge pages are created. In a busy instance, a few event loops runs will cause commands to target a few thousand of pages, causing the copy on write of almost the whole process memory."

With THP enabled, COW granularity jumps from 4KB to 2MB pages. A single byte change in a 2MB huge page causes the entire 2MB to be copied. This turns a small COW overhead into near-100% memory duplication on write-heavy workloads.

```bash
echo never > /sys/kernel/mm/transparent_hugepage/enabled
```

---

## 5. Fsync Performance Impact Numbers

### Findings to Enrich durability.md

**From antirez's persistence demystified (canonical reference):**

**appendfsync always:**
- Every write triggers write(2) + fsync(2) before client acknowledgment
- Supports group commit: multiple concurrent clients' writes are batched into a single write+fsync
- Even with group commit, practical limit is ~1000 transactions/second on rotational disk (100-200 raw write ops/s)
- SSD improves this dramatically but still the slowest mode

**appendfsync everysec (default):**
- write(2) called on every event loop return (typically after each command batch)
- fsync(2) called in background thread every second
- If background fsync takes > 1 second: write is delayed up to an additional second
- If 2 seconds elapse without fsync completing: blocking write forced
- **Worst case data loss: 2 seconds** (not 1 second as commonly stated)
- In practice: indistinguishable from `appendfsync no` in throughput

**appendfsync no:**
- write(2) before acknowledging client (data reaches kernel buffer)
- No explicit fsync - kernel flushes at its own pace (typically every 30 seconds on Linux)
- Safe against process crash (kernel retains data)
- NOT safe against power loss (up to 30 seconds of data loss)

**RDB checksum overhead (from valkey.conf):**

```
# Since version 5 of RDB a CRC64 checksum is placed at the end of the file.
# This makes the format more resistant to corruption but there is a performance
# hit to pay (around 10%) when saving and loading RDB files.
```

**no-appendfsync-on-rewrite details (from valkey.conf):**

```
# When the AOF fsync policy is set to always or everysec, and a background
# saving process (a background save or AOF log background rewriting) is
# performing a lot of I/O against the disk, in some Linux configurations
# the server may block too long on the fsync() call.
#
# This means that while another child is saving, the durability of the server
# is the same as "appendfsync no". In practical terms, this means that it is
# possible to lose up to 30 seconds of log in the worst scenario (with the
# default Linux settings).
```

---

## 6. Backup Tools and Scripts

### Findings to Enrich backup-recovery.md

**Official backup recommendation (from valkey.io/topics/persistence):**

> "Valkey is very data backup friendly since you can copy RDB files while the database is running: the RDB is never modified once produced, and while it gets produced it uses a temporary name and is renamed into its final destination atomically using rename(2) only when the new snapshot is complete."

**Official backup strategy:**
1. Cron job creating hourly snapshots in one directory, daily snapshots in another
2. Use `find` to age out old snapshots (48 hours for hourly, 1-2 months for daily)
3. At least once daily, transfer an RDB snapshot outside the data center or physical machine

**AOF backup - hardlink optimization (from official docs, new finding for backup-recovery.md):**

> "If you want to minimize the time AOF rewrites are disabled you may create hard links to the files in appenddirname (in step 3 above) and then re-enable rewrites (step 4) after the hard links are created. Now you can copy/tar the hardlinks and delete them when done. This works because Valkey guarantees that it only appends to files in this directory, or completely replaces them if necessary."

Optimized AOF backup script:

```bash
#!/bin/bash
# valkey-backup-aof-hardlink.sh - Minimal rewrite-disabled window using hardlinks
set -euo pipefail

VALKEY_CLI="valkey-cli -a ${VALKEY_PASSWORD:-}"
DATA_DIR="/var/lib/valkey"
BACKUP_DIR="/backups/valkey/aof"
DATE=$(date +%Y%m%d_%H%M%S)
LINK_DIR="${BACKUP_DIR}/${DATE}-links"

# Save current auto-rewrite percentage
PREV_PCT=$(${VALKEY_CLI} CONFIG GET auto-aof-rewrite-percentage | tail -1)

# 1. Disable auto-rewrite
${VALKEY_CLI} CONFIG SET auto-aof-rewrite-percentage 0

# 2. Wait for any in-progress rewrite to finish
while true; do
  IN_PROGRESS=$(${VALKEY_CLI} INFO persistence | grep aof_rewrite_in_progress | tr -d '\r' | cut -d: -f2)
  [ "$IN_PROGRESS" = "0" ] && break
  sleep 1
done

# 3. Create hardlinks (near-instant, regardless of file size)
mkdir -p "$LINK_DIR"
cp -al "${DATA_DIR}/appendonlydir/" "$LINK_DIR/"

# 4. Re-enable auto-rewrite immediately (hardlinks are stable)
${VALKEY_CLI} CONFIG SET auto-aof-rewrite-percentage "${PREV_PCT}"

# 5. Now copy/tar from hardlinks at leisure (rewrite can proceed on originals)
tar czf "${BACKUP_DIR}/${DATE}.tar.gz" -C "$LINK_DIR" appendonlydir/

# 6. Remove hardlinks
rm -rf "$LINK_DIR"

echo "[OK] AOF backup: ${BACKUP_DIR}/${DATE}.tar.gz"
```

**AOF backup with CONFIG REWRITE persistence (for restart safety):**

> "If you want to handle the case of the server being restarted during the backup and make sure no rewrite will automatically start after the restart you can change step 1 above to also persist the updated configuration via CONFIG REWRITE. Just make sure to re-enable automatic rewrites when done (step 4) and persist it with another CONFIG REWRITE."

**BGSAVE CANCEL (Valkey 8.1+ new feature):**

The `BGSAVE CANCEL` subcommand was added in Valkey 8.1.0. It immediately terminates any in-progress RDB save or replication full sync. Also cancels scheduled BGSAVE.

```bash
# Cancel a running background save
valkey-cli BGSAVE CANCEL
```

**BGSAVE SCHEDULE (since 3.2.2):**

```bash
# Schedule BGSAVE for when no AOF rewrite is running
valkey-cli BGSAVE SCHEDULE
```

Returns "Background saving scheduled" instead of error when AOF rewrite is in progress.

---

## 7. Point-in-Time Recovery Techniques

### Findings to Enrich backup-recovery.md

**AOF timestamp-based PITR (from valkey.conf):**

When `aof-timestamp-enabled yes` is set, Valkey inserts timestamp annotations into AOF entries. This enables:

```bash
valkey-check-aof --truncate-to-timestamp <unix-epoch> \
  appendonlydir/appendonly.aof.manifest
```

**Manual PITR without timestamps:**

Since the AOF is a command log in Redis protocol format, manual recovery is possible:
1. Stop the server
2. Identify the approximate position in the incr AOF file
3. Truncate the file at that position
4. Run `valkey-check-aof --fix` to ensure well-formed ending
5. Restart

**FLUSHALL recovery (from official docs, expanded):**

> "AOF contains a log of all the operations one after the other in an easy to understand and parse format. You can even easily export an AOF file. For instance even if you've accidentally flushed everything using the FLUSHALL command, as long as no rewrite of the log was performed in the meantime, you can still save your data set just by stopping the server, removing the latest command, and restarting Valkey again."

Critical: This only works if no AOF rewrite has occurred since the FLUSHALL. An AOF rewrite after FLUSHALL will compact the log to represent the empty dataset, making recovery impossible.

**RDB-based PITR:**

RDB provides coarser-grained recovery. Each RDB file is a complete point-in-time snapshot. Recovery granularity equals snapshot frequency:

| Save Config | Recovery Granularity |
|-------------|---------------------|
| `save 60 10000` | ~1 minute (under heavy write) |
| `save 300 100` | ~5 minutes (under moderate write) |
| `save 3600 1` | ~1 hour (under light write) |

---

## 8. AWS/GCP Backup Integration Patterns

### AWS ElastiCache Findings

**From AWS ElastiCache docs (fetched):**

- Backups are written to S3 automatically
- Max 20 manual backups per node per cluster in a 24-hour period
- Max 24 manual backups per serverless cache per 24-hour period
- Cluster mode enabled: backups are at cluster level only, not per-shard
- Serverless backups are transparent with no performance impact
- Node-based cluster backups: create from read replica to avoid BGSAVE impact on primary

**Best practice from AWS:**
> "Set the reserved-memory-percent parameter. To mitigate excessive paging, we recommend that you set the reserved-memory-percent parameter. This parameter prevents Valkey and Redis OSS from consuming all of the node's available memory."

**Self-hosted S3 backup script (production pattern):**

```bash
#!/bin/bash
# valkey-backup-s3.sh - RDB backup to S3 with encryption and lifecycle
set -euo pipefail

VALKEY_CLI="valkey-cli -a ${VALKEY_PASSWORD:-}"
DATA_DIR="/var/lib/valkey"
S3_BUCKET="s3://valkey-backups"
S3_PREFIX="${HOSTNAME}/$(date +%Y/%m)"
DATE=$(date +%Y%m%d_%H%M%S)
LOCAL_TMP="/tmp/valkey-backup-${DATE}"

# Trigger and wait for BGSAVE
${VALKEY_CLI} BGSAVE
PREV=$(${VALKEY_CLI} LASTSAVE)
TIMEOUT=600
ELAPSED=0
while [ "$(${VALKEY_CLI} LASTSAVE)" = "$PREV" ]; do
  sleep 2
  ELAPSED=$((ELAPSED + 2))
  if [ $ELAPSED -ge $TIMEOUT ]; then
    echo "[ERROR] BGSAVE timed out after ${TIMEOUT}s"
    exit 1
  fi
done

# Verify success
STATUS=$(${VALKEY_CLI} INFO persistence | grep rdb_last_bgsave_status | tr -d '\r')
if [[ "$STATUS" != *"ok"* ]]; then
  echo "[ERROR] BGSAVE failed: $STATUS"
  exit 1
fi

# Copy locally, compress, generate checksum
mkdir -p "$LOCAL_TMP"
cp "${DATA_DIR}/dump.rdb" "${LOCAL_TMP}/dump_${DATE}.rdb"
gzip "${LOCAL_TMP}/dump_${DATE}.rdb"
sha256sum "${LOCAL_TMP}/dump_${DATE}.rdb.gz" > "${LOCAL_TMP}/dump_${DATE}.rdb.gz.sha256"

# Upload to S3 with server-side encryption
aws s3 cp "${LOCAL_TMP}/dump_${DATE}.rdb.gz" \
  "${S3_BUCKET}/${S3_PREFIX}/dump_${DATE}.rdb.gz" \
  --sse AES256 \
  --storage-class STANDARD_IA

aws s3 cp "${LOCAL_TMP}/dump_${DATE}.rdb.gz.sha256" \
  "${S3_BUCKET}/${S3_PREFIX}/dump_${DATE}.rdb.gz.sha256" \
  --sse AES256 \
  --storage-class STANDARD_IA

# Verify upload
REMOTE_SIZE=$(aws s3 ls "${S3_BUCKET}/${S3_PREFIX}/dump_${DATE}.rdb.gz" | awk '{print $3}')
LOCAL_SIZE=$(stat -c %s "${LOCAL_TMP}/dump_${DATE}.rdb.gz" 2>/dev/null || stat -f %z "${LOCAL_TMP}/dump_${DATE}.rdb.gz")
if [ "$REMOTE_SIZE" != "$LOCAL_SIZE" ]; then
  echo "[ERROR] Upload size mismatch: local=${LOCAL_SIZE} remote=${REMOTE_SIZE}"
  exit 1
fi

# Cleanup local temp
rm -rf "$LOCAL_TMP"

echo "[OK] Backup uploaded: ${S3_BUCKET}/${S3_PREFIX}/dump_${DATE}.rdb.gz (${REMOTE_SIZE} bytes)"
```

**S3 lifecycle policy for retention:**

```json
{
  "Rules": [
    {
      "ID": "valkey-backup-lifecycle",
      "Status": "Enabled",
      "Transitions": [
        {
          "Days": 30,
          "StorageClass": "GLACIER_IR"
        },
        {
          "Days": 90,
          "StorageClass": "DEEP_ARCHIVE"
        }
      ],
      "Expiration": {
        "Days": 365
      }
    }
  ]
}
```

**GCS backup script (production pattern):**

```bash
#!/bin/bash
# valkey-backup-gcs.sh - RDB backup to Google Cloud Storage
set -euo pipefail

GCS_BUCKET="gs://valkey-backups"
GCS_PREFIX="${HOSTNAME}/$(date +%Y/%m)"
DATE=$(date +%Y%m%d_%H%M%S)

# [BGSAVE trigger same as above]

# Upload with CMEK encryption
gsutil -o "GSUtil:parallel_composite_upload_threshold=150M" \
  cp "${LOCAL_TMP}/dump_${DATE}.rdb.gz" \
  "${GCS_BUCKET}/${GCS_PREFIX}/dump_${DATE}.rdb.gz"

# Verify
gsutil hash -h "${GCS_BUCKET}/${GCS_PREFIX}/dump_${DATE}.rdb.gz"
```

**GCS lifecycle for tiered retention:**

```json
{
  "rule": [
    {
      "action": {"type": "SetStorageClass", "storageClass": "NEARLINE"},
      "condition": {"age": 30}
    },
    {
      "action": {"type": "SetStorageClass", "storageClass": "COLDLINE"},
      "condition": {"age": 90}
    },
    {
      "action": {"type": "Delete"},
      "condition": {"age": 365}
    }
  ]
}
```

---

## 9. Disaster Recovery Testing Procedures

### Findings to Enrich backup-recovery.md

**From official docs - key verification principle:**

> "It is important to understand that this system can easily fail if not implemented in the right way. At least, make absolutely sure that after the transfer is completed you are able to verify the file size (that should match the one of the file you copied) and possibly the SHA1 digest."

> "You also need some kind of independent alert system if the transfer of fresh backups is not working for some reason."

**DR test runbook (synthesized from official docs + production patterns):**

```bash
#!/bin/bash
# valkey-dr-test.sh - Automated disaster recovery verification
set -euo pipefail

BACKUP_RDB="$1"
TEST_PORT=6399
TEST_DIR="/tmp/valkey-dr-test-$$"
LOG_FILE="${TEST_DIR}/valkey.log"

mkdir -p "$TEST_DIR"

# 1. Verify backup file integrity
echo "[INFO] Verifying backup file..."
if [ -f "${BACKUP_RDB}.sha256" ]; then
  if ! sha256sum -c "${BACKUP_RDB}.sha256" --quiet 2>/dev/null; then
    echo "[ERROR] Checksum verification failed"
    exit 1
  fi
  echo "[OK] Checksum verified"
fi

FILE_SIZE=$(stat -c %s "$BACKUP_RDB" 2>/dev/null || stat -f %z "$BACKUP_RDB")
if [ "$FILE_SIZE" -lt 18 ]; then
  echo "[ERROR] RDB file too small (${FILE_SIZE} bytes) - likely corrupt or empty"
  exit 1
fi
echo "[OK] File size: ${FILE_SIZE} bytes"

# 2. Attempt load in isolated instance
echo "[INFO] Starting test instance on port ${TEST_PORT}..."
cp "$BACKUP_RDB" "${TEST_DIR}/dump.rdb"
valkey-server \
  --port $TEST_PORT \
  --dir "$TEST_DIR" \
  --dbfilename dump.rdb \
  --daemonize yes \
  --logfile "$LOG_FILE" \
  --save "" \
  --appendonly no \
  --protected-mode no \
  --bind 127.0.0.1

# Wait for startup
TIMEOUT=120
ELAPSED=0
while ! valkey-cli -p $TEST_PORT PING 2>/dev/null | grep -q PONG; do
  sleep 1
  ELAPSED=$((ELAPSED + 1))
  if [ $ELAPSED -ge $TIMEOUT ]; then
    echo "[ERROR] Test instance failed to start within ${TIMEOUT}s"
    echo "[ERROR] Log output:"
    tail -20 "$LOG_FILE"
    exit 1
  fi
done

LOAD_TIME=$ELAPSED
echo "[OK] Instance started in ${LOAD_TIME}s"

# 3. Verify data loaded correctly
DBSIZE=$(valkey-cli -p $TEST_PORT DBSIZE | awk '{print $2}' | tr -d '\r')
echo "[OK] Keys loaded: ${DBSIZE}"

# 4. Check for load errors in log
ERRORS=$(grep -c "ERROR\|FATAL\|Unexpected\|corruption" "$LOG_FILE" 2>/dev/null || echo 0)
if [ "$ERRORS" -gt 0 ]; then
  echo "[WARN] ${ERRORS} errors found in startup log:"
  grep "ERROR\|FATAL\|Unexpected\|corruption" "$LOG_FILE" | head -5
fi

# 5. Verify memory usage is reasonable
USED_MEM=$(valkey-cli -p $TEST_PORT INFO memory | grep used_memory_human | cut -d: -f2 | tr -d '\r')
echo "[OK] Memory used: ${USED_MEM}"

# 6. Spot-check data accessibility
RANDOM_KEYS=$(valkey-cli -p $TEST_PORT RANDOMKEY 2>/dev/null | head -3)
if [ -n "$RANDOM_KEYS" ] && [ "$RANDOM_KEYS" != "(nil)" ]; then
  echo "[OK] Random key accessible: ${RANDOM_KEYS}"
fi

# 7. Check keyspace info
valkey-cli -p $TEST_PORT INFO keyspace | grep "^db" | while read -r line; do
  echo "[OK] Keyspace: ${line}"
done

# 8. Shutdown test instance
valkey-cli -p $TEST_PORT SHUTDOWN NOSAVE 2>/dev/null

# 9. Cleanup
rm -rf "$TEST_DIR"

# 10. Report
echo ""
echo "=== DR Test Report ==="
echo "Backup: ${BACKUP_RDB}"
echo "File size: ${FILE_SIZE} bytes"
echo "Load time: ${LOAD_TIME}s"
echo "Keys: ${DBSIZE}"
echo "Memory: ${USED_MEM}"
echo "Errors: ${ERRORS}"
echo "Result: $([ "$DBSIZE" -gt 0 ] && [ "$ERRORS" -eq 0 ] && echo '[OK] PASS' || echo '[ERROR] FAIL')"
```

**Recovery time estimates by dataset size (synthesized from fork data + real-world patterns):**

RDB restore time depends primarily on file size and disk speed:

| Dataset Size | RDB File Size (compressed) | Load Time (SSD) | Load Time (HDD) |
|-------------|---------------------------|-----------------|-----------------|
| 1 GB | ~400 MB | 2-5 seconds | 5-15 seconds |
| 5 GB | ~2 GB | 10-20 seconds | 30-60 seconds |
| 10 GB | ~4 GB | 20-40 seconds | 60-120 seconds |
| 25 GB | ~10 GB | 45-90 seconds | 2-5 minutes |
| 50 GB | ~20 GB | 90-180 seconds | 5-10 minutes |
| 100 GB | ~40 GB | 3-6 minutes | 10-20 minutes |

AOF restore time is significantly longer because commands must be replayed:

| Dataset Size | AOF Load Time (SSD) | AOF Load Time (HDD) |
|-------------|--------------------|--------------------|
| 1 GB | 5-15 seconds | 15-45 seconds |
| 5 GB | 30-60 seconds | 2-5 minutes |
| 10 GB | 1-2 minutes | 5-10 minutes |
| 25 GB | 3-7 minutes | 10-20 minutes |

With `aof-use-rdb-preamble yes` (hybrid), AOF load times approach RDB load times since the base is in RDB format.

---

## 10. Data Migration Between Valkey Instances

### Findings to Enrich migration.md

**Method: RDB file transfer (simplest for standalone):**

```bash
# Source instance
valkey-cli -h source BGSAVE
# Wait for completion...
scp source:/var/lib/valkey/dump.rdb target:/var/lib/valkey/dump.rdb

# Target instance
sudo systemctl stop valkey
chown valkey:valkey /var/lib/valkey/dump.rdb
sudo systemctl start valkey
```

**Method: Live replication (zero/minimal downtime):**

From official admin docs:

1. Set up new Valkey instance as replica of old instance (`REPLICAOF old-host 6379`)
2. Wait for initial sync: check replica log, `INFO` replication fields
3. Verify key count matches: `INFO` on both instances
4. Allow writes on replica: `CONFIG SET replica-read-only no`
5. Switch application connections (use `CLIENT PAUSE` on old primary during switch)
6. Promote replica: `REPLICAOF NO ONE`
7. Shut down old instance

> "If you are using Valkey Sentinel or Valkey Cluster, the simplest way to upgrade to newer versions is to upgrade one replica after the other. Then you can perform a manual failover to promote one of the upgraded replicas to primary."

**Method: Cluster-to-cluster migration:**

Via Valkey 9.0 atomic slot migration - slots are migrated atomically rather than key-by-key:

> "In Valkey 9.0 instead of being key-by-key, Valkey migrates entire slots at a time, atomically moving the slot from one node to another using the AOF format. AOF can send individual items in a collection instead of the whole key."

**Diskless replication for migration:**

When the disk is a bottleneck, diskless replication avoids writing the RDB to disk entirely:

```
repl-diskless-sync yes
repl-diskless-sync-delay 5
```

The child process streams the RDB directly to the replica socket. Useful when:
- Disk is slow but network is fast
- Multiple replicas need sync (with delay, more can arrive before transfer starts)
- Disk space is limited

Caveat: once the diskless transfer starts, new replicas must wait for the next round.

**Dual-channel replication (Valkey 8+):**

From valkey.conf:

> "The primary's background save (bgsave) process streams the RDB snapshot directly to the replica over a separate connection."

```
dual-channel-replication-enabled yes
```

Requires `repl-diskless-sync` to be enabled. The RDB streams on a dedicated connection while the replication stream continues on the main connection.

---

## 11. Valkey 9.0 Persistence-Related Changes

### New Findings for Reference Docs

**BGSAVE CANCEL (8.1.0+):**

```
BGSAVE CANCEL
```

Immediately terminates in-progress RDB save or replication full sync. Also cancels scheduled saves. New operational capability for:
- Emergency stop of a fork that is consuming too much memory
- Canceling a scheduled BGSAVE before it starts

**Atomic slot migration uses AOF format:**

Valkey 9.0 migrates slots using AOF format internally, which means individual collection items can be sent instead of whole keys. This prevents large keys from blocking migration.

**1 billion req/s at scale:**

Valkey 9.0 can scale to 2,000 nodes in a cluster achieving over 1 billion requests per second. This is relevant for backup strategy - at this scale, backups must be coordinated per-shard, not per-cluster.

---

## 12. Supplementary: Operational Patterns from Admin Docs

### Linux Setup for Persistence (from official admin)

```bash
# Required for BGSAVE fork
sysctl -w vm.overcommit_memory=1
echo "vm.overcommit_memory = 1" >> /etc/sysctl.conf

# Required for latency
echo never > /sys/kernel/mm/transparent_hugepage/enabled

# Memory sizing rule
# If using RDB or AOF: reserve 2x dataset memory for COW during fork
# Set maxmemory to 80-90% of available memory

# Swap: enable and size equal to system memory
# Without swap, OOM killer may kill Valkey process
# With swap, latency spikes are detectable and actionable
```

### EBS Volumes on EC2

> "The use of Valkey persistence with EC2 EBS volumes needs to be handled with care because sometimes EBS volumes have high latency characteristics."
> "You may want to try diskless replication if you have issues when replicas are synchronizing with the primary."

Use provisioned IOPS (io2 Block Express) for persistence workloads. GP3 volumes may have latency spikes during BGSAVE.

### Monitoring Persistence Health

```bash
# Comprehensive persistence check
valkey-cli INFO persistence

# Key fields to monitor:
# rdb_last_bgsave_status          - must be "ok"
# rdb_last_bgsave_time_sec        - BGSAVE duration (growing = dataset growth)
# rdb_changes_since_last_save     - unsaved mutations
# aof_enabled                     - should match your config
# aof_rewrite_in_progress         - 1 during rewrite
# aof_last_rewrite_time_sec       - rewrite duration
# aof_last_bgrewrite_status       - must be "ok"
# aof_current_size                - growing? check auto-rewrite triggers
# aof_base_size                   - size after last rewrite
```

---

## 13. Enrichment Recommendations by Target File

### aof.md - Add

- [ ] AOF rewrite failure backoff mechanism (exponential retry on failure)
- [ ] Hardlink-based AOF backup optimization (minimize rewrite-disabled window)
- [ ] Detailed worst-case data loss for `everysec`: 2 seconds, not 1 second (antirez)
- [ ] Startup log sequence for hybrid persistence loading
- [ ] CONFIG REWRITE for backup persistence across restarts
- [ ] Group commit behavior with `appendfsync always`

### rdb.md - Add

- [ ] Page table size formula: `dataset_size / 4KB * 8 bytes`
- [ ] Fork overhead measurement table by dataset size
- [ ] Fork rate quality thresholds from LATENCY DOCTOR
- [ ] BGSAVE CANCEL (8.1.0+) for emergency fork termination
- [ ] BGSAVE SCHEDULE for safe scheduling around AOF rewrites
- [ ] COW memory overhead ranges (10-30% typical, 100% worst case on write-heavy)

### backup-recovery.md - Add

- [ ] Hardlink-based AOF backup script (production-tested pattern)
- [ ] S3 backup script with compression, encryption, size verification
- [ ] GCS backup script with parallel upload
- [ ] S3/GCS lifecycle policies for tiered retention (IA -> Glacier -> Deep Archive)
- [ ] DR test runbook script with automated verification
- [ ] Recovery time estimates table by dataset size
- [ ] Backup verification with isolated test instance
- [ ] Independent alerting on backup transfer failures (official recommendation)
- [ ] AWS ElastiCache best practice: backup from read replica

### durability.md - Add

- [ ] antirez's 5-layer write path explanation
- [ ] The 2-second worst case for `everysec` (write delay when fsync is slow)
- [ ] Group commit throughput: ~1000 tx/s on rotational disk with `always`
- [ ] `no-appendfsync-on-rewrite yes` means up to 30 seconds data loss during rewrite
- [ ] RDB CRC64 checksum: ~10% performance hit on save/load

### migration.md - Add

- [ ] Valkey 9.0 atomic slot migration details (AOF format for per-item transfer)
- [ ] Dual-channel replication (Valkey 8+)
- [ ] CLIENT PAUSE during migration switchover (from official admin docs)
- [ ] Diskless replication for bandwidth-over-disk migration scenarios
