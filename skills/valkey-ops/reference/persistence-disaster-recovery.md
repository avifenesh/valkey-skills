# Disaster Recovery

Use when performing disaster recovery - restoring from RDB or AOF backups, recovering from accidental FLUSHALL.

Standard Redis DR procedures apply. See Redis docs for general recovery steps.

## Valkey-Specific Names

All procedures use `valkey-server`, `valkey-cli`, `valkey-check-aof` instead of their Redis equivalents. Data paths and file names are the same.

## RDB Recovery

```bash
sudo systemctl stop valkey
cp /backups/dump_DATE.rdb /var/lib/valkey/dump.rdb
chown valkey:valkey /var/lib/valkey/dump.rdb
sudo systemctl start valkey
valkey-cli DBSIZE
```

## AOF Recovery (accidental FLUSHALL)

Stop server immediately, edit last `.incr.aof` file in `appendonlydir/`, remove the FLUSHALL line, restart. Do not let the server rewrite the AOF before stopping.

## Point-in-Time Recovery

```bash
valkey-check-aof --truncate-to-timestamp 1711699200 \
  appendonlydir/appendonly.aof.manifest
```

Requires `aof-timestamp-enabled yes` to have been set before the incident.

## Backup Verification

```bash
valkey-server --port 6399 --dir /tmp/valkey-verify \
  --dbfilename backup.rdb --daemonize yes
valkey-cli -p 6399 DBSIZE
valkey-cli -p 6399 SHUTDOWN NOSAVE
```
