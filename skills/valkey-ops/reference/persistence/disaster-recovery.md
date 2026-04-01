Use when performing disaster recovery - restoring from RDB or AOF backups, recovering from accidental FLUSHALL, point-in-time recovery, or verifying backup integrity.

# Disaster Recovery

## Contents

- Recover from RDB (line 16)
- Recover from AOF (line 37)
- Recover from Accidental FLUSHALL (line 53)
- Point-in-Time Recovery (line 77)
- Recovery Time Estimates (line 87)
- Backup Verification (line 104)
- See Also (line 140)

---

## Recover from RDB

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

## Recover from AOF

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

## Recover from Accidental FLUSHALL

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

## Point-in-Time Recovery

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

---

## See Also

- [backup-strategies](backup-strategies.md) - Automated backup scripts, off-site backup, retention
- [rdb](rdb.md) - RDB configuration
- [aof](aof.md) - AOF configuration
