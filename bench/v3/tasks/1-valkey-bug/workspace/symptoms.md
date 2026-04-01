# Bug Report: Hash Field Expiration Anomaly

## Environment

- Valkey 9.0.3 (custom build)
- Single instance, no replication
- Default configuration

## Observed Symptoms

### 1. HEXPIRE succeeds on deleted fields

After deleting a field from a hash with HDEL, running HEXPIRE on that same field returns 1 (success) instead of the expected 0 (field does not exist). Per the Valkey documentation, HEXPIRE should return 0 when the specified field does not exist in the hash.

### 2. Ghost TTLs visible via HEXPIRETIME

HEXPIRETIME returns a positive TTL value for fields that do not appear in HGETALL output. The field was deleted and is not retrievable, yet the server maintains expiration metadata for it.

### 3. Slow memory growth

On a long-running instance where fields are frequently created, deleted, and then accidentally expired, memory usage reported by INFO MEMORY grows steadily. The growth is slow - approximately 50-100 bytes per orphaned TTL entry - but accumulates over time with no natural cleanup.

### 4. DEBUG DIGEST inconsistency

Running DEBUG DIGEST on the key before and after the HDEL + HEXPIRE sequence shows the digest changing on the HEXPIRE call, even though the field no longer exists in the hash. This indicates the server is modifying internal metadata for a non-existent field.

## Reproduction

See reproduce.sh for a minimal reproduction case. The core sequence is:

```
HSET key field value
HDEL key field
HEXPIRE key 3600 FIELDS 1 field   # returns 1, should return 0
HEXPIRETIME key FIELDS 1 field    # returns a future timestamp, should return -2
```

## Impact Assessment

- **Data correctness**: Return values from HEXPIRE are wrong for deleted fields
- **Observability**: HEXPIRETIME reports TTLs for fields that do not exist, confusing monitoring
- **Memory**: Orphaned expiration metadata accumulates without cleanup
- **Replication**: Unknown - not tested, but TTL metadata may replicate to replicas
