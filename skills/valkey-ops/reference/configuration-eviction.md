# Eviction Policies

Use when choosing or tuning the maxmemory eviction policy. All 8 policy names verified against `maxmemory_policy_enum` in `src/config.c`.

## Contents

- When Eviction Happens (line 18)
- The 8 Eviction Policies (line 24)
- Policy Selection Guide (line 45)
- LRU/LFU Precision (line 92)
- LFU Tuning (line 104)
- Monitoring Eviction (line 143)
- Common Mistakes (line 159)

---

## When Eviction Happens

Eviction triggers when `used_memory` exceeds `maxmemory`. If `maxmemory` is `0` (the default), eviction is disabled and Valkey uses all available system memory.

The eviction check runs before every command that might add data. The eviction loop continues until memory is back under the limit or no more keys can be evicted.

## The 8 Eviction Policies

Source-verified from `maxmemory_policy_enum[]` in config.c (line 60-69):

| Policy | Scope | Algorithm | Default |
|--------|-------|-----------|---------|
| `noeviction` | - | Reject writes with OOM error | Yes (source default) |
| `allkeys-lru` | All keys | Approximate Least Recently Used | No |
| `allkeys-lfu` | All keys | Approximate Least Frequently Used | No |
| `allkeys-random` | All keys | Random selection | No |
| `volatile-lru` | Keys with TTL only | Approximate Least Recently Used | No |
| `volatile-lfu` | Keys with TTL only | Approximate Least Frequently Used | No |
| `volatile-random` | Keys with TTL only | Random selection | No |
| `volatile-ttl` | Keys with TTL only | Shortest remaining TTL first | No |

Set the policy:

```
CONFIG SET maxmemory-policy allkeys-lru
```

## Policy Selection Guide

### noeviction

**What happens**: Returns OOM error on write commands. Read commands still work.

**Use when**: Valkey is a primary data store and you never want data silently removed. Your application must handle OOM errors gracefully.

**Risk**: Write operations fail when memory is full. If your application does not handle this, it breaks.

### allkeys-lru

**What happens**: Evicts the least recently accessed key from the entire keyspace.

**Use when**: General-purpose cache. Most workloads benefit from this policy. Good when you do not know your access pattern in advance.

**Trade-off**: LRU is approximate - Valkey samples `maxmemory-samples` keys (default 5) and evicts the least recently used among the sample. Not a true LRU.

### allkeys-lfu

**What happens**: Evicts the least frequently accessed key. Frequency decays over time.

**Use when**: Some keys are accessed much more than others (popularity-based). Better than LRU when a small set of keys accounts for most of the traffic.

**Trade-off**: New keys start with a low frequency counter and may be evicted before they prove popular. Tune `lfu-decay-time` and `lfu-log-factor` to adjust.

### volatile-lru / volatile-lfu / volatile-random

**What happens**: Same algorithms as allkeys variants, but only consider keys that have a TTL set.

**Use when**: You have a mix of persistent keys (no TTL) that must never be evicted and cache keys (with TTL) that can be evicted. The persistent keys act as a protected set.

**Risk**: If no keys have a TTL set, volatile policies behave like `noeviction` - they return OOM errors because there are no eviction candidates.

### volatile-ttl

**What happens**: Evicts keys with the shortest remaining TTL first.

**Use when**: You explicitly control eviction priority through TTL values. Keys you set with shorter TTLs are evicted first. Useful when TTL encodes priority - lower TTL means lower priority.

### allkeys-random

**What happens**: Evicts a random key from the entire keyspace.

**Use when**: All keys have roughly equal access frequency and importance. Rare in practice. Has the lowest CPU overhead of all policies.


## LRU/LFU Precision

Valkey does not implement true LRU/LFU - it approximates using random sampling.

| Parameter | Default | Description |
|-----------|---------|-------------|
| `maxmemory-samples` | `5` | Keys sampled per eviction cycle. Higher = more accurate, more CPU. |
| `maxmemory-eviction-tenacity` | `10` | Effort level (0-100). Higher = tries harder to free memory. |

At `maxmemory-samples 5`, the approximation is close to true LRU for most workloads. At `10`, it is nearly indistinguishable from true LRU. Going above 10 has diminishing returns.


## LFU Tuning

LFU uses a probabilistic counter (Morris counter) that saturates at 255. Two parameters control its behavior:

| Parameter | Default | Description |
|-----------|---------|-------------|
| `lfu-log-factor` | `10` | Controls how quickly the counter reaches saturation. Higher = slower saturation. |
| `lfu-decay-time` | `1` | Minutes between counter halving. 0 = never decay. |

### lfu-log-factor

With factor 10 (default), roughly 1 million hits are needed to saturate the counter. With factor 100, roughly 10 million. Set higher if you need to differentiate between very popular keys.

| Factor | Hits to reach 255 |
|--------|--------------------|
| 0 | ~255 |
| 1 | ~1,000 |
| 10 | ~1,000,000 |
| 100 | ~10,000,000 |

### lfu-decay-time

Controls how fast old access patterns are forgotten. At `1` (default), the counter halves every minute when not accessed. Set to `0` to never decay - not recommended because formerly hot keys stay hot forever.

### When LFU Outperforms LRU

LFU provides better hit ratios when:
- Strong frequency skew - some keys are accessed 1000x more than others
- The hot-set is relatively stable over time
- Scan-like operations exist that would "pollute" LRU cache (one-time full scans push out hot keys)

LRU is better when:
- Access patterns shift rapidly (today's hot keys are tomorrow's cold keys)
- Recency matters more than frequency
- The workload is mostly power-law distributed (LRU already handles this well)

Use `OBJECT FREQ <key>` to inspect LFU counters on individual keys. Compare `keyspace_hits / (keyspace_hits + keyspace_misses)` in `INFO stats` before and after policy changes.


## Monitoring Eviction

```bash
# Check eviction stats
valkey-cli INFO stats | grep evicted_keys

# Check current policy
valkey-cli CONFIG GET maxmemory-policy

# Check memory usage vs limit
valkey-cli INFO memory | grep -E 'used_memory_human|maxmemory_human'
```

If `evicted_keys` is rising rapidly, either increase `maxmemory` or accept higher cache miss rates. If eviction is happening but memory is not decreasing, check for large client output buffers (`INFO clients`).


## Common Mistakes

1. **Leaving maxmemory at 0 in production**: Valkey grows until the OS OOM-killer terminates it. Always set `maxmemory`.

2. **Using volatile-* with no TTLs**: If no keys have TTLs, volatile policies cannot evict anything and return OOM errors.

3. **Setting maxmemory-samples too high**: Values above 10 waste CPU for negligible accuracy gains.

4. **Not monitoring eviction rate**: Sudden spikes in `evicted_keys` mean your working set exceeds memory. This causes cache misses and application latency.
