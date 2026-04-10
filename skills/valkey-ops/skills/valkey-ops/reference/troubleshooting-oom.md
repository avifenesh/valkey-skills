# Out of Memory (OOM) Diagnosis and Resolution

Use when Valkey returns OOM errors on writes or the Linux OOM killer terminates Valkey.

Standard Redis OOM diagnosis and resolution applies - set `maxmemory`, choose eviction policy, check fragmentation, enable `vm.overcommit_memory`. See Redis docs for full OOM troubleshooting.

## Valkey-Specific: maxmemory-clients

Valkey adds `maxmemory-clients` (absent in Redis) - caps aggregate client buffer memory independently of `maxmemory`:

```bash
valkey-cli CONFIG SET maxmemory-clients 5%
```

Defaults to `0` (unlimited). Client buffers are not counted against `maxmemory` unless this is set.

## Standard Diagnosis

```bash
valkey-cli INFO memory | grep -E "used_memory|maxmemory|mem_fragmentation"
valkey-cli MEMORY DOCTOR
valkey-cli --bigkeys
valkey-cli MEMORY USAGE <key> SAMPLES 0
dmesg | grep -i "out of memory"
```

## Key Defaults (source-verified)

- `maxmemory`: `0` (unlimited) - always set explicitly
- `maxmemory-policy`: `noeviction`
- `maxmemory-clients`: `0` (unlimited)

## Production Thresholds

Alert at `used_memory / maxmemory` > 75% (warn) / 90% (critical). Replication and AOF buffers are NOT counted against `maxmemory` - size `maxmemory` 10-20% lower than available RAM when using replication.
