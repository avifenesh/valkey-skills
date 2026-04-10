# BloomObject Struct and Scaling Mechanism

Use when understanding the top-level bloom filter container, how sub-filters scale out, false positive tightening, memory limit enforcement, or the VALIDATESCALETO logic.

Source: `src/bloom/utils.rs`

## Contents

- BloomObject Struct (line 22)
- Constructor Methods (line 39)
- Scaling Mechanism (line 62)
- FP Rate Tightening (line 84)
- Non-Scaling Behavior (line 108)
- Memory Limit Enforcement (line 119)
- Maximum Filters and VALIDATESCALETO (line 150)
- Item Operations (line 168)
- Accessor Methods (line 183)
- Drop Implementation (line 198)

---

## BloomObject Struct

Defined at line 92 of `src/bloom/utils.rs`. The top-level container stored as a Valkey data type (`bloomfltr`), holding one or more sub-filters in a chain.

```rust
#[derive(Serialize, Deserialize)]
pub struct BloomObject {
    expansion: u32,                    // Scale factor per new filter (0 = non-scaling)
    fp_rate: f64,                      // Target false positive rate for the object
    tightening_ratio: f64,             // FP decay multiplier per scale-out (default 0.5)
    is_seed_random: bool,              // Whether the seed was randomly generated
    filters: Vec<Box<BloomFilter>>,    // Chain of sub-filters
}
```

`expansion` doubles as a non-scaling indicator: when set to 0, scaling is disabled and only one filter is allowed.

## Constructor Methods

Three constructors exist:

**`new_reserved`** - Creates a fresh BloomObject. Called by `BF.RESERVE` and `BF.INSERT` (when creating). Accepts `fp_rate`, `tightening_ratio`, `capacity`, `expansion`, a seed tuple `(Option<[u8; 32]>, bool)`, and `validate_size_limit`. The seed tuple allows passing either a fixed seed or `None` for random. Validates size before creation when `validate_size_limit` is true.

```rust
pub fn new_reserved(
    fp_rate: f64,
    tightening_ratio: f64,
    capacity: i64,
    expansion: u32,
    seed: (Option<[u8; 32]>, bool),
    validate_size_limit: bool,
) -> Result<BloomObject, BloomError>
```

**`from_existing`** - Reconstructs from RDB load or BF.LOAD restore. Takes all fields directly, no validation beyond what the caller performs.

**`create_copy_from`** - Deep copy for the `COPY` command. Iterates all filters and calls `BloomFilter::create_copy_from` on each.

All three constructors call `bloom_object_incr_metrics_on_new_create` to update global atomic counters.

## Scaling Mechanism

Scaling happens inside `add_item` (line 308) when the last filter reaches capacity. The full sequence:

1. **Check existence**: Scan all filters via `item_exists`. If the item is already present in any filter, return 0 (no-op).

2. **Try the last filter**: If `num_items < capacity` on the last filter, add the item there.

3. **Non-scaling check**: If `expansion == 0`, return `NonScalingFilterFull`.

4. **Filter count check**: If `num_filters == BLOOM_NUM_FILTERS_PER_OBJECT_LIMIT_MAX` (i32::MAX), return `MaxNumScalingFilters`.

5. **Calculate new FP rate**: `fp_rate * tightening_ratio^num_filters`. Must stay above `f64::MIN_POSITIVE` or return `FalsePositiveReachesZero`.

6. **Calculate new capacity**: `last_filter.capacity * expansion` via `checked_mul`. Overflow returns `BadCapacity`.

7. **Validate size**: If `validate_size_limit` is true, call `validate_size_before_scaling` to check the total object size against `bloom-memory-usage-limit`.

8. **Create new filter**: Use `BloomFilter::with_fixed_seed` with the same seed as the first filter (`self.seed()`). All sub-filters in an object share the same seed.

9. **Add and push**: Set the item in the new filter, increment `num_items`, push to `self.filters`.

## FP Rate Tightening

The `calculate_fp_rate` function (line 385) computes the FP rate for the Nth filter:

```rust
pub fn calculate_fp_rate(
    fp_rate: f64,
    num_filters: i32,
    tightening_ratio: f64,
) -> Result<f64, BloomError> {
    match fp_rate * tightening_ratio.powi(num_filters) {
        x if x > f64::MIN_POSITIVE => Ok(x),
        _ => Err(BloomError::FalsePositiveReachesZero),
    }
}
```

With default tightening ratio 0.5 and FP rate 0.01:
- Filter 0: `0.01 * 0.5^0 = 0.01`
- Filter 1: `0.01 * 0.5^1 = 0.005`
- Filter 2: `0.01 * 0.5^2 = 0.0025`

Each successive filter uses a stricter FP rate. The union of independent bloom filters with geometrically decreasing FP rates converges to the original target, maintaining the configured FP rate as the object scales.

## Non-Scaling Behavior

When `expansion == 0`, the bloom object operates as a single fixed-capacity filter:

- `BF.RESERVE` with `NONSCALING` sets `expansion = 0` internally
- `add_item` returns `BloomError::NonScalingFilterFull` when the single filter reaches capacity
- The `filters` vec always contains exactly one entry
- `VALIDATESCALETO` and `NONSCALING` cannot be combined - the module returns `NON_SCALING_AND_VALIDATE_SCALE_TO_IS_INVALID`

The expansion range for scaling filters is 1 to `BLOOM_EXPANSION_MAX` (u32::MAX). The default expansion is 2, configured via `bloom-expansion`.

## Memory Limit Enforcement

Three validation functions enforce the `bloom-memory-usage-limit` config (default 128MB):

**`validate_size`** (line 216) - Core check. Compares a byte count against `BLOOM_MEMORY_LIMIT_PER_OBJECT`:

```rust
pub fn validate_size(bytes: usize) -> bool {
    if bytes > configs::BLOOM_MEMORY_LIMIT_PER_OBJECT.load(Ordering::Relaxed) as usize {
        return false;
    }
    true
}
```

**`validate_size_before_create`** (line 208) - Called during `new_reserved`. Computes the projected size of a new BloomObject with one filter:

```rust
let bytes = size_of::<BloomObject>()
    + size_of::<Box<BloomFilter>>()
    + BloomFilter::compute_size(capacity, fp_rate);
```

**`validate_size_before_scaling`** (line 200) - Called during `add_item` scale-out. Adds the projected new filter size to the current `memory_usage()`:

```rust
let bytes = self.memory_usage() + BloomFilter::compute_size(capacity, fp_rate);
```

Size validation is skipped for replicated commands (when `must_obey_client` returns true). This prevents replicas from rejecting operations that the primary already accepted.

## Maximum Filters and VALIDATESCALETO

The maximum number of filters per object is `BLOOM_NUM_FILTERS_PER_OBJECT_LIMIT_MAX`, set to `i32::MAX` (2,147,483,647). In practice, the 128MB memory limit is hit long before this.

The `calculate_max_scaled_capacity` function (line 500) simulates scaling to answer two questions:

1. **BF.INFO MAXSCALEDCAPACITY**: How many total items can this object hold before hitting memory or FP limits? Called with `validate_scale_to = -1`.

2. **BF.INSERT VALIDATESCALETO**: Can this object scale to hold at least N total items? Called with the user-provided target.

The simulation loop:
- Starts with the initial capacity and iterates, multiplying by `expansion` each round
- For each simulated filter, checks FP rate degradation and memory limits
- Tracks `filters_memory_usage` cumulatively, computing vec capacity as `next_power_of_two` to match actual allocation behavior
- Returns the total capacity reached, or an error if the target cannot be met

Two errors are possible: `ValidateScaleToExceedsMaxSize` (memory limit) and `ValidateScaleToFalsePositiveInvalid` (FP rate reaches zero).

## Item Operations

**`add_item`** returns `Result<i64, BloomError>`:
- `Ok(0)` - item already existed (checked across all filters)
- `Ok(1)` - item was added (to last filter or a new scaled-out filter)
- `Err(...)` - non-scaling full, max filters, size limit, capacity overflow

**`item_exists`** checks all filters: `self.filters.iter().any(|filter| filter.check(item))`.

**`cardinality`** sums `num_items` across all filters.

**`capacity`** sums `capacity` across all filters.

**`starting_capacity`** returns the first filter's capacity (the initial size before scaling).

## Accessor Methods

| Method | Returns | Notes |
|--------|---------|-------|
| `expansion()` | `u32` | 0 for non-scaling |
| `fp_rate()` | `f64` | Object-level target rate |
| `tightening_ratio()` | `f64` | Decay multiplier per filter |
| `is_seed_random()` | `bool` | Random vs fixed seed mode |
| `num_filters()` | `usize` | Current filter count |
| `filters()` | `&Vec<Box<BloomFilter>>` | Immutable filter access |
| `filters_mut()` | `&mut Vec<Box<BloomFilter>>` | Mutable access (defrag, decode) |
| `seed()` | `[u8; 32]` | First filter's seed (shared by all) |
| `memory_usage()` | `usize` | Total bytes including all filters |
| `free_effort()` | `usize` | Filter count (for async free threshold) |

## Drop Implementation

`BloomObject` implements `Drop` (line 690) to decrement global metrics:

```rust
impl Drop for BloomObject {
    fn drop(&mut self) {
        metrics::BLOOM_OBJECT_TOTAL_MEMORY_BYTES.fetch_sub(
            self.bloom_object_memory_usage(), Ordering::Relaxed,
        );
        metrics::BLOOM_NUM_OBJECTS.fetch_sub(1, Ordering::Relaxed);
    }
}
```

Decrements the object-level overhead only. Each `BloomFilter` in the vec has its own `Drop` that decrements filter-level metrics separately.