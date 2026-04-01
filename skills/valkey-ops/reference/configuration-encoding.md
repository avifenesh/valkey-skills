# Memory Encoding Thresholds

Use when tuning memory usage for small collections or diagnosing unexpected memory consumption. All thresholds verified against `src/config.c`.

## Contents

- How Compact Encodings Work (line 16)
- Encoding Thresholds by Data Type (line 23)
- Checking Current Encoding (line 99)
- Tuning for Memory Efficiency (line 124)
- Memory Impact Example (line 160)

---

## How Compact Encodings Work

Valkey stores small collections in compact formats (listpack, intset) that use significantly less memory - up to 10x less than standard encodings. When a collection grows beyond a threshold, Valkey converts it to the full encoding (hashtable, skiplist, quicklist).

This conversion is one-way: once a collection switches to the full encoding, it stays there even if elements are removed. Rewriting the key (DEL + re-add) is the only way to get the compact encoding back.


## Encoding Thresholds by Data Type

### Hash

| Parameter | Default | Compact Encoding | Full Encoding |
|-----------|---------|-----------------|---------------|
| `hash-max-listpack-entries` | `512` | listpack | hashtable |
| `hash-max-listpack-value` | `64` bytes | listpack | hashtable |

A hash uses listpack when both conditions hold:
- Number of fields <= `hash-max-listpack-entries`
- All field names and values are <= `hash-max-listpack-value` bytes

Adding a 65-byte value to a 10-field hash triggers conversion to hashtable.

### Sorted Set (ZSet)

| Parameter | Default | Compact Encoding | Full Encoding |
|-----------|---------|-----------------|---------------|
| `zset-max-listpack-entries` | `128` | listpack | skiplist + hashtable |
| `zset-max-listpack-value` | `64` bytes | listpack | skiplist + hashtable |

Same dual-condition logic as hash. The full encoding uses both a skiplist (for range queries) and a hashtable (for O(1) member lookup).

### Set

| Parameter | Default | Compact Encoding | Full Encoding |
|-----------|---------|-----------------|---------------|
| `set-max-intset-entries` | `512` | intset | hashtable |
| `set-max-listpack-entries` | `128` | listpack | hashtable |
| `set-max-listpack-value` | `64` bytes | listpack | hashtable |

Sets have three possible encodings:
1. **intset**: When all elements are integers and count <= `set-max-intset-entries`. Most compact.
2. **listpack**: When elements include non-integers, count <= `set-max-listpack-entries`, and all values <= `set-max-listpack-value` bytes.
3. **hashtable**: When any threshold is exceeded.

### List

| Parameter | Default | Description |
|-----------|---------|-------------|
| `list-max-listpack-size` | `-2` | Max entries or bytes per quicklist node. |
| `list-compress-depth` | `0` | Number of uncompressed nodes at each end. 0 = no compression. |

Lists always use quicklist (a linked list of listpacks). The `list-max-listpack-size` parameter controls the size of each node:

| Value | Meaning |
|-------|---------|
| `-1` | 4 KB per listpack node |
| `-2` | 8 KB per listpack node (default) |
| `-3` | 16 KB per listpack node |
| `-4` | 32 KB per listpack node |
| `-5` | 64 KB per listpack node |
| Positive N | Max N entries per listpack node |

`list-compress-depth` enables LZF compression for interior nodes:
- `0`: No compression
- `1`: Compress all nodes except head and tail
- `2`: Compress all except the 2 nodes at each end

### Stream

| Parameter | Default | Description |
|-----------|---------|-------------|
| `stream-node-max-entries` | `100` | Max entries per radix tree node. |
| `stream-node-max-bytes` | `4096` | Max bytes per radix tree node. |

### HyperLogLog

| Parameter | Default | Description |
|-----------|---------|-------------|
| `hll-sparse-max-bytes` | `3000` | Max bytes before converting from sparse to dense representation. |

HyperLogLog starts in sparse encoding and converts to dense (12 KB fixed) when the sparse representation exceeds this threshold.


## Checking Current Encoding

Use `OBJECT ENCODING` to see what encoding a key uses:

```bash
valkey-cli OBJECT ENCODING mykey
```

Possible responses:
- `listpack` - compact sequential encoding
- `hashtable` - hash table encoding
- `skiplist` - sorted set full encoding
- `intset` - integer-only set encoding
- `quicklist` - list encoding (linked listpacks)
- `raw` - SDS string > 44 bytes
- `embstr` - embedded SDS string <= 44 bytes
- `int` - integer encoding for string values that fit in a long

Use `MEMORY USAGE` to check per-key memory:

```bash
valkey-cli MEMORY USAGE mykey
```


## Tuning for Memory Efficiency

### Increase Thresholds for Smaller Collections

If your collections are consistently small (e.g., hashes with 20-50 fields), the defaults already provide compact encoding. If you have many collections near the boundary, increasing thresholds keeps more of them compact:

```
hash-max-listpack-entries 1024
zset-max-listpack-entries 256
set-max-intset-entries 1024
```

**Trade-off**: Compact encodings have O(N) lookup within the listpack. Above ~500-1000 entries, the CPU cost of scanning the listpack may outweigh the memory savings. Profile before increasing thresholds beyond defaults.

### Reduce Thresholds for Lower Latency

If you need consistent O(1) operations and memory is not a concern:

```
hash-max-listpack-entries 0
zset-max-listpack-entries 0
set-max-listpack-entries 0
```

This forces all collections to use full encodings immediately.

### String Encoding Optimization

Strings have implicit encoding rules (not configurable):
- Integer values that fit in a `long` are stored as integers (8 bytes)
- Strings <= 44 bytes use `embstr` (single allocation, object + SDS together)
- Strings > 44 bytes use `raw` (separate allocation for SDS)

To maximize memory efficiency with strings, keep values under 44 bytes when possible.


## Memory Impact Example

A hash with 100 small fields:
- Listpack encoding: ~2-3 KB
- Hashtable encoding: ~10-15 KB

Multiply by millions of keys and the difference is significant. With 10 million hashes at 100 fields each:
- Listpack: ~25 GB
- Hashtable: ~120 GB
