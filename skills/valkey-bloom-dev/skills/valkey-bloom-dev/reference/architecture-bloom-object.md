# BloomObject - scaling container

Use when reasoning about the top-level bloom filter, scale-out, FP tightening, memory limits, or VALIDATESCALETO.

Source: `src/bloom/utils.rs`.

## Struct

```rust
#[derive(Serialize, Deserialize)]
pub struct BloomObject {
    expansion: u32,                 // 0 = non-scaling (single filter, NONSCALING keyword sets this)
    fp_rate: f64,
    tightening_ratio: f64,
    is_seed_random: bool,
    filters: Vec<Box<BloomFilter>>,
}
```

`expansion == 0` doubles as a non-scaling flag; the filter vec then always contains exactly one entry.

## Constructors

- `new_reserved(fp_rate, tightening_ratio, capacity, expansion, seed: (Option<[u8;32]>, bool), validate_size_limit)` - used by BF.RESERVE / BF.INSERT creation. Validates size when `validate_size_limit`.
- `from_existing(...)` - RDB load / BF.LOAD reconstruction, no validation.
- `create_copy_from(&BloomObject)` - deep copy for `COPY`; iterates filters, delegates to `BloomFilter::create_copy_from`.

All three call `bloom_object_incr_metrics_on_new_create`.

## Scale-out sequence (`add_item`)

1. `item_exists` across all filters - if present, return `Ok(0)`.
2. If last filter has room (`num_items < capacity`), add there.
3. `expansion == 0` -> `NonScalingFilterFull`.
4. `num_filters == BLOOM_NUM_FILTERS_PER_OBJECT_LIMIT_MAX` (`i32::MAX`) -> `MaxNumScalingFilters`.
5. New FP rate = `fp_rate * tightening_ratio^num_filters`. Below `f64::MIN_POSITIVE` -> `FalsePositiveReachesZero`.
6. New capacity = `last_filter.capacity * expansion` via `checked_mul`. Overflow -> `BadCapacity`.
7. If `validate_size_limit`, call `validate_size_before_scaling`.
8. Create new filter via `BloomFilter::with_fixed_seed(self.seed())` - **all sub-filters share the first filter's seed**.
9. Set item, increment `num_items`, push.

## FP tightening (`calculate_fp_rate`)

`fp_rate * tightening_ratio.powi(num_filters)`, returns `FalsePositiveReachesZero` when `<= f64::MIN_POSITIVE`.

Default tightening 0.5, fp_rate 0.01: filter N uses `0.01 * 0.5^N`. Geometric decay keeps the union's aggregate FP rate close to the original target.

## Memory limit enforcement

Three helpers against `BLOOM_MEMORY_LIMIT_PER_OBJECT` (default 128 MB):

| Function | Called by | Check |
|----------|-----------|-------|
| `validate_size(bytes)` | all three below | `bytes <= limit` |
| `validate_size_before_create(capacity, fp_rate)` | `new_reserved` | projected size of `BloomObject + one filter` |
| `validate_size_before_scaling(&self, capacity, fp_rate)` | `add_item` scale-out | `self.memory_usage() + new filter size` |

All three are skipped when `must_obey_client` returns true (replica / AOF replay). Primary never lets replicas reject what it accepted.

## VALIDATESCALETO and MAXSCALEDCAPACITY

`calculate_max_scaled_capacity` simulates scaling from `starting_capacity` multiplied by `expansion` each round, tracking cumulative filter memory with `next_power_of_two` (mimics `Vec` growth). Returns:

- `BF.INFO MAXSCALEDCAPACITY` (scale_to = -1) - total items reachable before memory or FP limit.
- `BF.INSERT VALIDATESCALETO <n>` - checks target; errors are `ValidateScaleToExceedsMaxSize` or `ValidateScaleToFalsePositiveInvalid`.

## Item operations

- `add_item` - `Ok(0)` dup, `Ok(1)` new, else `Err(BloomError)`.
- `item_exists` - `self.filters.iter().any(|f| f.check(item))`.
- `cardinality` / `capacity` - sum across filters.
- `starting_capacity` - first filter's capacity (used by MAXSCALEDCAPACITY, not total).

## Accessors

| Method | Returns | Note |
|--------|---------|------|
| `expansion()` | `u32` | 0 = non-scaling |
| `fp_rate()` / `tightening_ratio()` | `f64` | |
| `is_seed_random()` | `bool` | |
| `num_filters()` | `usize` | |
| `filters()` / `filters_mut()` | `&[/&mut] Vec<Box<BloomFilter>>` | mut used by defrag + decode |
| `seed()` | `[u8; 32]` | first filter's seed (shared by all) |
| `memory_usage()` | `usize` | object overhead + all filters |
| `free_effort()` | `usize` | filter count (threshold for async free) |

## Drop

Decrements `BLOOM_OBJECT_TOTAL_MEMORY_BYTES` by `bloom_object_memory_usage()` and `BLOOM_NUM_OBJECTS` by 1. Each `BloomFilter` has its own `Drop` that handles per-filter metrics separately.
