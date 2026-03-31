# Scalable Bloom Filter Architecture

Use when understanding bloom filter internals, memory layout, scaling behavior, hash functions, tightening ratio, or false positive management.

## Two-Layer Structure

The module uses a two-layer design defined in `src/bloom/utils.rs`:

**BloomObject** - top-level container stored as a Valkey data type (`bloomfltr`):

```rust
pub struct BloomObject {
    expansion: u32,          // Scale factor (0 = non-scaling)
    fp_rate: f64,            // Target false positive rate
    tightening_ratio: f64,   // FP decay per scale-out (default 0.5)
    is_seed_random: bool,    // Random vs fixed seed mode
    filters: Vec<Box<BloomFilter>>,  // Chain of sub-filters
}
```

**BloomFilter** - individual filter wrapping the `bloomfilter` crate:

```rust
pub struct BloomFilter {
    bloom: Box<bloomfilter::Bloom<[u8]>>,  // Bit vector + SipHash
    num_items: i64,   // Items currently stored
    capacity: i64,    // Max items before scaling
}
```

## Scaling Mechanism

When a filter reaches capacity:

1. Check `expansion > 0` (non-scaling filters return `NonScalingFilterFull`)
2. Calculate new FP rate: `fp_rate * tightening_ratio^num_filters`
3. Calculate new capacity: `last_filter.capacity * expansion`
4. Validate total object size against `bloom-memory-usage-limit` (default 128MB)
5. Create new `BloomFilter` with the same seed as the first filter
6. Push new filter to the `filters` vec

The tightening ratio ensures the overall bloom object maintains the configured FP rate as it scales. Each successive filter uses a stricter (lower) FP rate.

## Item Operations

**Add** (`add_item`): Check all filters for existence first (dedup). If not found, add to the last filter. If last filter is full, scale out and add to the new filter. Returns 1 for new item, 0 for existing.

**Exists** (`item_exists`): Scan all filters with `any()` - returns true if any filter reports the item present.

## Hash Function and Seeds

The module uses `bloomfilter::Bloom<[u8]>` which internally uses SipHash with a 32-byte seed.

Two seed modes controlled by `bloom-use-random-seed` config (default: true):
- **Random seed**: Each new BloomObject gets a unique random seed. All sub-filters in the same object share the first filter's seed.
- **Fixed seed**: Uses `configs::FIXED_SEED`, a hardcoded 32-byte array. Required for deterministic cross-instance behavior.

On replication, the primary always sends the exact seed to replicas via `BF.INSERT ... SEED <bytes>` for deterministic replication regardless of mode.

## Memory Layout and Sizing

Per-filter memory: `sizeof(BloomFilter) + sizeof(Bloom<[u8]>) + bitmap_bytes`

Where `bitmap_bytes = bloomfilter::Bloom::compute_bitmap_size(capacity, fp_rate)`.

Per-object overhead: `sizeof(BloomObject) + vec_capacity * sizeof(Box<BloomFilter>)`

The `bloom-memory-usage-limit` config (default 128MB) caps total memory per object. Size is validated before creation (`validate_size_before_create`) and before each scale-out (`validate_size_before_scaling`).

## Max Scaled Capacity

`calculate_max_scaled_capacity` simulates scaling to determine the maximum items a bloom object can hold before hitting the memory limit or FP rate degradation to zero. Exposed via `BF.INFO ... MAXSCALEDCAPACITY`.

## RDB Persistence

Save order (per object in `bloom_rdb_save`):
1. `num_filters`, `expansion`, `fp_rate`, `tightening_ratio`, `is_seed_random`
2. Per filter: `capacity`, then `num_items` (only for last filter), then raw bitmap bytes

Load (`load_from_rdb`): Reconstructs each `BloomFilter` from the saved bitmap using `BloomFilter::from_existing`. Validates size limits and seed consistency during restore.

Encoding version: `BLOOM_TYPE_ENCODING_VERSION = 1`. Load rejects newer versions.

## AOF Rewrite

Uses `BF.LOAD` command with a bincode-serialized representation of the entire `BloomObject`. The `encode_object` method prepends a version byte (`BLOOM_OBJECT_VERSION = 1`) to the bincode output.

## Defragmentation

The defrag callback (`bloom_defrag`) uses cursor-based incremental defragmentation:

1. For each filter: defrag the `BloomFilter` allocation, inner `Bloom` struct, and its bit vector
2. Defrag the filters `Vec` itself
3. Defrag the `BloomObject`

Uses `Defrag::should_stop_defrag()` to yield between filters. Controlled by `bloom-defrag-enabled` config.

## Metrics

Global atomic counters in `src/metrics.rs` track:
- `bloom_num_objects` - total bloom objects
- `bloom_total_memory_bytes` - aggregate memory
- `bloom_num_filters_across_objects` - total sub-filters
- `bloom_num_items_across_objects` - total items
- `bloom_capacity_across_objects` - total capacity
- `bloom_defrag_hits` / `bloom_defrag_misses`

Metrics are updated on create, drop, add, and scale-out. Exposed via `INFO bf`.

## Module Configs

| Config | Default | Range | Type |
|--------|---------|-------|------|
| `bloom-capacity` | 100 | 1..i64::MAX | i64 |
| `bloom-expansion` | 2 | 0..u32::MAX | i64 |
| `bloom-fp-rate` | "0.01" | (0, 1) exclusive | string/f64 |
| `bloom-tightening-ratio` | "0.5" | (0, 1) exclusive | string/f64 |
| `bloom-memory-usage-limit` | 128MB | 0..i64::MAX | i64 |
| `bloom-use-random-seed` | true | bool | bool |
| `bloom-defrag-enabled` | true | bool | bool |

FP rate and tightening ratio use string configs with a custom `on_string_config_set` handler that validates range and updates a `Mutex<f64>` static.
