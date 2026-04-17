# Memory Tuning

Use when sizing Valkey, picking encoding thresholds, or diagnosing fragmentation.

Redis-baseline mechanics - `maxmemory`, `maxmemory-policy` (noeviction / allkeys-lru / allkeys-lfu / allkeys-random / volatile-*), fork-COW behavior on BGSAVE, jemalloc fragmentation monitoring via `INFO memory`, `MEMORY STATS / DOCTOR / PURGE`, `OBJECT ENCODING` - carry over unchanged. What's below is Valkey-specific or ops-non-obvious.

## Divergent encoding defaults

Valkey 8.1 bumped `hash-max-listpack-entries` from 128 to **512**. Redis-trained mental models of "at 128 fields the hash promotes" are wrong on Valkey.

| Directive | Valkey default | Redis 7.2 default |
|-----------|---------------|-------------------|
| `hash-max-listpack-entries` | **512** | 128 |
| `hash-max-listpack-value` | 64 | 64 |
| `set-max-listpack-entries` | 128 | 128 |
| `zset-max-listpack-entries` | 128 | 128 |
| listpack value caps | 64 B | 64 B |
| `list-max-listpack-size` | `-2` (8 KB/node) | `-2` |

Knock-on effect: hashes that were "promoted" on Redis may stay listpack on Valkey. Lookups are O(N) on listpack but N is small; memory usage drops 2-5x versus hashtable. Keep the bump unless you see tail-latency spikes on hash reads.

## Built-in per-key savings (Valkey 8.0+ cluster; 9.0 embedded string)

Automatic, no tuning. Ops-visible effect: `used_memory` per key is lower than on Redis 7.2 for the same dataset. Relevant when capacity-planning a Redis -> Valkey migration at constant RAM.

- **Kvstore per-slot** (cluster mode only, 8.0+): 16,384 per-slot hashtables replace the single global hashtable. Drops per-key overhead, localizes rehashing to the touched slot.
- **Embedded key** (8.0+): key SDS lives inside the hashtable entry, saving a pointer dereference and an indirection per lookup.
- **Embedded string value** (9.0+): `shouldEmbedStringObject` returns true when the total allocation fits in 2 cache lines (128 bytes), including `robj` + optional key SDS + optional expire. Redis 7.2 used a flat 44-byte cutoff (`OBJ_ENCODING_EMBSTR_SIZE_LIMIT`) - Valkey's threshold is more generous and includes key+expire in the budget.

Effect on a 16-byte value + 32-byte key: Redis 7.2 needed separate allocations for the SDS key, SDS value, and `robj`; Valkey 9.0 fuses all three into one cache-line-friendly allocation.

## `maxmemory-clients` sizing (percentage form)

```
maxmemory-clients 5%     # percentage of maxmemory
maxmemory-clients 256mb  # absolute
```

The percentage form is evaluated at `maxmemory` SET time. Changing `maxmemory` without touching `maxmemory-clients` keeps the literal value from last evaluation. After a `maxmemory` bump, re-set the percentage or it silently becomes a smaller fraction.

Client buffers and replica output buffers are **not** counted toward eviction (`mem_not_counted_for_evict` in INFO memory). This matters when provisioning replica-heavy deployments: the primary's real RSS exceeds `maxmemory` by the sum of replica COB sizes plus the replication backlog.

## Eviction tenacity

`maxmemory-eviction-tenacity` (default 10, range 0-100). Controls how many keys per cycle the evictor samples per pass. Raising it burns more CPU in the eviction path but reclaims faster when memory pressure is continuous. Leave at 10 unless `evicted_keys / second` can't keep up with write rate.

## Active defrag tuning

Valkey's active defrag is jemalloc-only - the `activedefrag yes` knob is a no-op with other allocators (no error, just silently off). Valkey-specific tuning knob:

```
active-defrag-cycle-us 500       # base cycle duration (Valkey-only, default 500us)
active-defrag-threshold-lower 10 # start when frag > 10%
active-defrag-threshold-upper 100
active-defrag-cycle-min 1        # min CPU% for defrag
active-defrag-cycle-max 25
```

`active-defrag-cycle-us` replaces Redis's `active-defrag-ignore-bytes` as the primary time-slice knob. Raising it lets each defrag cycle do more work at the cost of longer per-cycle stalls - lower it when tail latency matters more than reclamation speed.

## Fragmentation thresholds (operator heuristics)

Same `mem_fragmentation_ratio = used_memory_rss / used_memory`:

| Ratio | Interpretation |
|-------|---------------|
| < 1.0 | Swapping to disk - investigate RSS vs `used_memory_peak` |
| 1.0-1.5 | Normal |
| 1.5-2.0 | Moderate - `MEMORY PURGE` or run an active defrag cycle |
| > 2.0 | High - enable `activedefrag` or schedule a restart |

## Fork headroom rule of thumb

Dataset fork RSS on a write-heavy workload can approach **2x parent RSS** under sustained writes. Classic planning: `maxmemory = 60-70% of node RAM`, reserving the rest for COW + client buffers + OS. On cache-only workloads where fork pressure is lower, 80% is defensible; on AOF+RDB with heavy writes, 50-60% is safer.
