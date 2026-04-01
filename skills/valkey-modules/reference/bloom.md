# valkey-bloom - Bloom Filter Data Structure

Use when implementing probabilistic membership testing, deduplication, cache warming, or migrating from Redis Bloom BF.* commands.

## Contents

- Overview (line 20)
- Commands (line 36)
- Scalable vs Non-Scalable Filters (line 62)
- Usage Examples (line 96)
- Client Integration (line 125)
- Use Cases (line 149)
- Error Rate and Memory (line 181)
- Version History (line 193)
- Client Library Compatibility (line 201)

---

## Overview

valkey-bloom adds Bloom filters as a native data type to Valkey. A Bloom filter is a space-efficient probabilistic data structure that answers "is this element in the set?" with either "definitely not" or "probably yes." False positives are possible; false negatives are not.

| Property | Value |
|----------|-------|
| Status | GA |
| License | BSD |
| Language | Rust (uses `bloomfilter::Bloom` crate, BSD-2-Clause) |
| Redis equivalent | RedisBloom (BF.* commands) |
| Compatibility | API compatible with Redis Bloom BF.* commands and client libraries |
| Valkey version | 8.0+ (8.0 requires `valkey_8_0` feature flag at build time; 8.1+ works by default) |
| Included in | valkey-bundle container image |

**Security update**: Version 1.0.1 fixes CVE-2026-21864 - a remote denial-of-service vulnerability triggered by malformed RESTORE commands. Upgrade immediately if running 1.0.0.

## Commands

### Adding Elements

| Command | Description |
|---------|-------------|
| `BF.ADD key item` | Add a single item to the filter. Creates the filter if it does not exist |
| `BF.MADD key item [item ...]` | Add multiple items in one call |
| `BF.INSERT key [CAPACITY cap] [ERROR rate] [EXPANSION exp] [SEED seed] [TIGHTENING ratio] [VALIDATESCALETO count] [NOCREATE] [NONSCALING] ITEMS item [item ...]` | Add items with creation options in a single command |

### Checking Membership

| Command | Description |
|---------|-------------|
| `BF.EXISTS key item` | Check if an item may exist in the filter. Returns 1 (probably yes) or 0 (definitely no) |
| `BF.MEXISTS key item [item ...]` | Check multiple items in one call |

### Filter Management

| Command | Description |
|---------|-------------|
| `BF.RESERVE key error_rate capacity [EXPANSION exp] [NONSCALING]` | Create a filter with specific error rate and capacity |
| `BF.INFO key [CAPACITY\|SIZE\|FILTERS\|ITEMS\|EXPANSION\|ERROR\|TIGHTENING\|MAXSCALEDCAPACITY]` | Get filter metadata |
| `BF.CARD key` | Return the number of items added to the filter |
| `BF.LOAD key data` | Restore a filter from serialized data |

## Scalable vs Non-Scalable Filters

### Scalable (Default)

When a scalable Bloom filter reaches its initial capacity, it creates additional sub-filters. Each new sub-filter has a tighter error rate to maintain the overall false positive probability.

```
BF.RESERVE myfilter 0.01 1000
# Creates a scalable filter: 1% error rate, initial capacity 1000
# Default expansion factor is 2 (each sub-filter doubles in capacity)
```

Control the expansion factor:

```
BF.RESERVE myfilter 0.01 1000 EXPANSION 4
# Each new sub-filter will be 4x the capacity of the previous
```

### Non-Scalable

A non-scalable filter has a fixed capacity. Adds beyond capacity fail. Non-scalable filters use less memory and have more predictable performance - only one sub-filter to check.

```
BF.RESERVE myfilter 0.01 1000 NONSCALING
# Fixed at 1000 items, returns error if exceeded
```

Or via `BF.INSERT`:

```
BF.INSERT myfilter CAPACITY 1000 ERROR 0.01 NONSCALING ITEMS item1 item2
```

## Usage Examples

```
# Create a filter and add items
BF.ADD seen_urls "https://example.com/page1"
BF.ADD seen_urls "https://example.com/page2"

# Check membership
BF.EXISTS seen_urls "https://example.com/page1"
# (integer) 1 - probably exists

BF.EXISTS seen_urls "https://example.com/page3"
# (integer) 0 - definitely does not exist

# Bulk operations
BF.MADD dedup_filter item1 item2 item3 item4
BF.MEXISTS dedup_filter item1 item5
# 1) (integer) 1
# 2) (integer) 0

# Pre-configure a filter
BF.RESERVE email_filter 0.001 100000
# 0.1% false positive rate, capacity for 100,000 items

# Get filter info
BF.INFO email_filter
# Capacity, Size, Number of filters, Items inserted, Expansion rate
```

## Client Integration

valkey-bloom does not have a dedicated GLIDE API class. Use `custom_command` to call Bloom filter commands from any GLIDE client:

```python
# Python
await client.custom_command(["BF.ADD", "myfilter", "item1"])
exists = await client.custom_command(["BF.EXISTS", "myfilter", "item1"])
```

```typescript
// Node.js
await client.customCommand(["BF.ADD", "myfilter", "item1"]);
const exists = await client.customCommand(["BF.EXISTS", "myfilter", "item1"]);
```

```java
// Java
client.customCommand(new String[]{"BF.ADD", "myfilter", "item1"}).get();
Object exists = client.customCommand(new String[]{"BF.EXISTS", "myfilter", "item1"}).get();
```

See the **valkey-glide** skill for more on `custom_command` usage patterns.

## Use Cases

### Deduplication

Prevent processing the same item twice. Check `BF.EXISTS` before processing - if absent, the item is guaranteed new.

```
# Web crawler deduplication
BF.EXISTS crawled_urls "https://example.com/new-page"
# 0 -> definitely new, safe to crawl
BF.ADD crawled_urls "https://example.com/new-page"
```

### Membership Testing at Scale

Check if a username, email, or ID exists in a large dataset without querying a database. Bloom filters use a fraction of the memory a Set would require.

```
# Username availability pre-check
BF.EXISTS taken_usernames "alice_new"
# 0 -> definitely available (skip DB query)
# 1 -> might be taken (query DB to confirm)
```

### Cache Warming Prevention

Track requested keys. On a cache miss, check the Bloom filter before hitting the origin database - if the key was never seen, it likely does not exist in the database either.

### Rate Limiting Approximation

Track unique visitors or events within a time window using a Bloom filter per window. More memory-efficient than HyperLogLog when individual membership checks are also needed.

## Error Rate and Memory

The error rate (false positive probability) directly affects memory usage. Lower error rates require more bits per item.

| Error Rate | Bits per Item (approx) | Memory for 1M Items |
|------------|----------------------|---------------------|
| 1% (0.01) | ~10 bits | ~1.2 MB |
| 0.1% (0.001) | ~14 bits | ~1.7 MB |
| 0.01% (0.0001) | ~19 bits | ~2.3 MB |

Compare with a Valkey Set storing 1 million 20-byte strings: approximately 50-60 MB. Bloom filters use 20-40x less memory for membership testing.

## Version History

| Version | Date | Highlights |
|---------|------|------------|
| 1.0.0-rc1 | March 2025 | First release candidate |
| 1.0.0 | April 2025 | Initial GA release |
| 1.0.1 | February 2026 | Security fix: CVE-2026-21864 (remote DoS from malformed RESTORE command) |

## Client Library Compatibility

API compatible with existing Redis bloom filter client libraries. Works with valkey-py, valkey-java, valkey-go, and their Redis equivalents (redis-py, Jedis, go-redis) without code changes.

