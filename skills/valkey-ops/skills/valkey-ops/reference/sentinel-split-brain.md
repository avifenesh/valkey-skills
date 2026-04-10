# Split-Brain Prevention

Use when planning for network partition scenarios or configuring write safety for Sentinel-managed Valkey deployments.

Standard Redis Sentinel split-brain prevention applies - majority requirement, single-vote-per-epoch, TILT mode. See Redis docs for the full model.

## Valkey Config for Write Safety

```
min-replicas-to-write 1
min-replicas-max-lag 10
```

Primary stops accepting writes (returns `-NOREPLICAS`) when fewer than `min-replicas-to-write` replicas have acknowledged within `min-replicas-max-lag` seconds. Limits data loss window to the lag period.

## Operational Checks

```bash
valkey-cli -p 26379 SENTINEL ckquorum mymaster
valkey-cli -p 26379 SENTINEL replicas mymaster
valkey-cli INFO replication   # check replica lag
valkey-cli -p 26379 SENTINEL sentinels mymaster   # should show odd count >= 3
```

## Rules

- Never deploy 2 Sentinels - cannot achieve majority after 1 failure
- Use `WAIT 1 <timeout>` for critical individual writes that require replication confirmation
- Use Sentinel-aware client libraries that subscribe to `+switch-master` events
