# Memory Encoding Thresholds

Use when tuning memory usage for small collections or diagnosing unexpected memory consumption.

Standard Redis compact encoding model applies (listpack, intset, quicklist). See Redis docs for general behavior.

## Valkey Defaults vs Redis Defaults

| Parameter | Valkey Default | Redis Default | Note |
|-----------|---------------|---------------|------|
| `hash-max-listpack-entries` | `512` | `128` | Valkey 4x higher - keep more hashes compact |
| `hash-max-listpack-value` | `64` bytes | `64` bytes | Same |
| `zset-max-listpack-entries` | `128` | `128` | Same |
| `zset-max-listpack-value` | `64` bytes | `64` bytes | Same |
| `set-max-intset-entries` | `512` | `512` | Same |
| `set-max-listpack-entries` | `128` | `128` | Same |

The `hash-max-listpack-entries 512` default in Valkey means significantly more hashes stay in compact listpack encoding compared to Redis. This is intentional - Valkey favors memory efficiency for the common case of moderate-sized hashes.

## Checking Encoding

```bash
valkey-cli OBJECT ENCODING mykey
valkey-cli MEMORY USAGE mykey
```

## Encoding Conversion Is One-Way

Once a collection upgrades to hashtable/skiplist, it stays there even if elements are removed. DEL and re-add is the only way back to compact encoding.
