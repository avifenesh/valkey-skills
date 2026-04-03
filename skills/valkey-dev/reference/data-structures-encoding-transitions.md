# Encoding Transitions

Use when you need to understand how Valkey automatically selects compact encodings for small collections and transitions to full-featured structures when thresholds are exceeded.

Standard Redis encoding transition pattern. Valkey-specific differences:

- **Hash default** `hash-max-listpack-entries` is 512 (Redis 7.x uses 128)
- **Set default** `set-max-intset-entries` is 512 (Redis 7.x uses 512 - same)
- **EMBSTR threshold** is dynamic via `shouldEmbedStringObject()` - accounts for optional embedded key, optional expire, and SDS value within a 64-byte cache line (Valkey 8.0+ embeds key+value+expire in a single allocation)
- Full encoding for Hash/Set/Sorted Set uses `hashtable` (Valkey's new open-addressing table) instead of dict
- Lists CAN convert back from QUICKLIST to LISTPACK when shrinking below half the threshold (avoids oscillation)
- `zsetConvertToListpackIfNeeded` can convert sorted sets back to listpack after bulk operations

| Data Type | Compact | Full | Count Threshold | Size Threshold |
|-----------|---------|------|-----------------|----------------|
| String | EMBSTR/INT | RAW | N/A | >64 bytes total embedded |
| List | LISTPACK | QUICKLIST | `list-max-listpack-size` (-2) | Same |
| Set | INTSET | HASHTABLE | `set-max-intset-entries` (512) | Non-integer |
| Set | LISTPACK | HASHTABLE | `set-max-listpack-entries` (128) | `set-max-listpack-value` (64) |
| Sorted Set | LISTPACK | SKIPLIST+HT | `zset-max-listpack-entries` (128) | `zset-max-listpack-value` (64) |
| Hash | LISTPACK | HASHTABLE | `hash-max-listpack-entries` (512) | `hash-max-listpack-value` (64) |
