# BloomFilter Struct and bloomfilter Crate

Use when understanding the individual sub-filter implementation, how the bloomfilter crate is integrated, seed handling (random vs fixed), item add/check flow, or how filters are reconstructed from RDB data.

Source: `src/bloom/utils.rs`, `Cargo.toml`

## Contents

- BloomFilter Struct (line 20)
- The bloomfilter Crate (line 38)
- Constructor Methods (line 52)
- Seed Handling (line 95)
- Item Add and Check Flow (line 121)
- Memory Sizing (line 145)
- Copy and Serialization Support (line 171)
- Drop Implementation (line 185)

---

## BloomFilter Struct

Defined at line 566 of `src/bloom/utils.rs`. Each BloomFilter wraps a single instance of the external `bloomfilter` crate's `Bloom<[u8]>` type.

```rust
#[derive(Serialize, Deserialize)]
pub struct BloomFilter {
    #[serde(serialize_with = "serialize", deserialize_with = "deserialize_boxed_bloom")]
    bloom: Box<bloomfilter::Bloom<[u8]>>,  // Bit vector + SipHash hasher
    num_items: i64,                         // Items currently stored
    capacity: i64,                          // Max items before parent scales
}
```

The `bloom` field uses custom serde helpers from the `bloomfilter` crate: `serialize` and `deserialize` (re-exported as `deserialize_boxed_bloom` to produce a `Box`). These handle the internal bit vector and hasher state during bincode serialization for AOF rewrite via BF.LOAD.

The comment at line 559 notes the struct is approximately 200 bytes (not counting the heap-allocated bit vector). The source comment mentions `u32` for `num_items` and `capacity`, but the actual fields are `i64` - the 128MB per-object memory limit makes u32::MAX items unreachable regardless.

## The bloomfilter Crate

The module depends on `bloomfilter` version 3.0.1 (`Cargo.toml`). This external crate provides:

- **Bit vector storage**: `Bloom<[u8]>` stores the filter bits as a `Vec<u8>`
- **SipHash hashing**: Uses SipHash-1-3 with a 32-byte seed to derive two 64-bit SIP keys
- **Optimal sizing**: `new_for_fp_rate(capacity, fp_rate)` calculates the optimal number of bits and hash functions for the desired false positive rate
- **Bitmap operations**: `set(item)` hashes and sets bits, `check(item)` hashes and tests bits
- **Serde support**: `serialize`/`deserialize` functions for the `Bloom` struct, used by bincode
- **Bitmap access**: `as_slice()` returns the raw bit vector as `&[u8]` for RDB persistence, `from_slice(bitmap)` reconstructs from raw bytes
- **Size computation**: `compute_bitmap_size(capacity, fp_rate)` returns the byte count for the bit vector without allocating
- **Seed access**: `seed()` returns the 32-byte seed, `to_bytes()` serializes the full state
- **Realloc callback**: `realloc_large_heap_allocated_objects(callback)` supports custom reallocation of the internal Vec for defragmentation

## Constructor Methods

**`with_fixed_seed`** (line 585) - Creates a filter with a specific 32-byte seed:

```rust
pub fn with_fixed_seed(fp_rate: f64, capacity: i64, fixed_seed: &[u8; 32]) -> BloomFilter {
    let bloom = bloomfilter::Bloom::new_for_fp_rate_with_seed(
        capacity as usize, fp_rate, fixed_seed,
    ).expect("We expect bloomfilter::Bloom<[u8]> creation to succeed");
    BloomFilter { bloom: Box::new(bloom), num_items: 0, capacity }
}
```

Used for: scale-out (new sub-filters inherit the first filter's seed), replica creation (deterministic replication via `BF.INSERT ... SEED`), and fixed-seed mode.

**`with_random_seed`** (line 599) - Creates a filter with a crate-generated random seed:

```rust
pub fn with_random_seed(fp_rate: f64, capacity: i64) -> BloomFilter {
    let bloom = Box::new(
        bloomfilter::Bloom::new_for_fp_rate(capacity as usize, fp_rate)
            .expect("We expect bloomfilter::Bloom<[u8]> creation to succeed"),
    );
    BloomFilter { bloom, num_items: 0, capacity }
}
```

Used only for creating the very first filter of a BloomObject when `bloom-use-random-seed` is true and no explicit seed is provided.

**`from_existing`** (line 614) - Reconstructs from a raw bitmap during RDB load:

```rust
pub fn from_existing(bitmap: &[u8], num_items: i64, capacity: i64) -> BloomFilter {
    let bloom = bloomfilter::Bloom::from_slice(bitmap)
        .expect("We expect bloomfilter::Bloom<[u8]> creation to succeed");
    BloomFilter { bloom: Box::new(bloom), num_items, capacity }
}
```

The `from_slice` method reconstructs the entire `Bloom` struct from the raw bytes, including the SipHash keys embedded in the bitmap header. This is how RDB restore recovers the hasher state without explicitly saving seed data per filter.

All three constructors call `bloom_filter_incr_metrics_on_new_create` to update global counters.

## Seed Handling

The 32-byte seed is the foundation for deterministic behavior. It flows through the system as follows:

**FIXED_SEED constant** (line 68 of `src/configs.rs`):

```rust
pub const FIXED_SEED: [u8; 32] = [
    89, 15, 245, 34, 234, 120, 17, 218, 167, 20, 216, 9, 59, 62, 123, 217,
    29, 137, 138, 115, 62, 152, 136, 135, 48, 127, 151, 205, 40, 7, 51, 131,
];
```

**Seed modes** controlled by `bloom-use-random-seed` config (default: true):

| Mode | First Filter Creation | Sub-Filter Creation | Replication |
|------|----------------------|--------------------|----|
| Random seed | `with_random_seed` | `with_fixed_seed(self.seed())` | Sends actual seed via `SEED` arg |
| Fixed seed | `with_fixed_seed(FIXED_SEED)` | `with_fixed_seed(self.seed())` | Sends FIXED_SEED via `SEED` arg |

All sub-filters within a BloomObject always share the same seed as the first filter, regardless of seed mode. The `seed()` method on BloomObject delegates to the first filter's `seed()`.

**RDB load seed validation** (line 123 of `data_type.rs`): When `is_seed_random` is false, each restored filter's seed is checked against `FIXED_SEED`. If they don't match, the restore fails with "Object in fixed seed mode, but seed does not match FIXED_SEED."

**`is_seed_random` flag**: Stored in the BloomObject and persisted to RDB. Controls whether the fixed-seed validation is applied during restore. When true, any seed is accepted (since it was randomly generated and embedded in the bitmap).

## Item Add and Check Flow

**Check** (`check` method, line 681):

```rust
pub fn check(&self, item: &[u8]) -> bool {
    self.bloom.check(item)
}
```

Delegates directly to the crate. The crate hashes the item bytes with SipHash, derives bit positions, and tests each bit in the internal Vec.

**Set** (`set` method, line 685):

```rust
pub fn set(&mut self, item: &[u8]) {
    self.bloom.set(item)
}
```

Delegates to the crate. Hashes the item and sets the corresponding bits. Note that `set` does not check for existence - the caller (`BloomObject::add_item`) handles dedup by scanning all filters first.

The `BloomFilter` does not track whether individual items were already present. The `num_items` counter is incremented by the parent `BloomObject::add_item` only when a genuinely new item is added.

## Memory Sizing

**`number_of_bytes`** (line 668) - Actual memory of this filter:

```rust
pub fn number_of_bytes(&self) -> usize {
    size_of::<BloomFilter>()
        + size_of::<bloomfilter::Bloom<[u8]>>()
        + (self.bloom.len() / 8) as usize
}
```

Three components: the `BloomFilter` struct itself, the heap-allocated `Bloom<[u8]>` struct, and the bit vector bytes (`bloom.len()` returns bits, divided by 8).

**`compute_size`** (line 675) - Projected size without allocation:

```rust
pub fn compute_size(capacity: i64, fp_rate: f64) -> usize {
    size_of::<BloomFilter>()
        + size_of::<bloomfilter::Bloom<[u8]>>()
        + bloomfilter::Bloom::<[u8]>::compute_bitmap_size(capacity as usize, fp_rate)
}
```

Used by `BloomObject::validate_size_before_create` and `validate_size_before_scaling` to check memory limits before allocating.

## Copy and Serialization Support

**`create_copy_from`** (line 630) - For the `COPY` command:

```rust
pub fn create_copy_from(bf: &BloomFilter) -> BloomFilter {
    BloomFilter::from_existing(&bf.bloom.to_bytes(), bf.num_items, bf.capacity)
}
```

Serializes the bloom to bytes via `to_bytes()`, then reconstructs via `from_existing`. This produces a fully independent copy with its own heap allocation.

**Serde integration**: The `#[serde]` attributes on the `bloom` field use the crate's `serialize` and a custom `deserialize_boxed_bloom` wrapper (line 576) that deserializes into a `Box<Bloom<[u8]>>`. This is used by bincode for the AOF rewrite path (BF.LOAD encoding).

## Drop Implementation

`BloomFilter` implements `Drop` (line 699) to decrement global metrics:

```rust
impl Drop for BloomFilter {
    fn drop(&mut self) {
        metrics::BLOOM_NUM_FILTERS_ACROSS_OBJECTS.fetch_sub(1, Ordering::Relaxed);
        metrics::BLOOM_OBJECT_TOTAL_MEMORY_BYTES.fetch_sub(
            self.number_of_bytes(), Ordering::Relaxed,
        );
        metrics::BLOOM_NUM_ITEMS_ACROSS_OBJECTS.fetch_sub(
            self.num_items as u64, Ordering::Relaxed,
        );
        metrics::BLOOM_CAPACITY_ACROSS_OBJECTS.fetch_sub(
            self.capacity as u64, Ordering::Relaxed,
        );
    }
}
```

This decrements four counters: filter count, memory bytes, item count, and capacity. Combined with BloomObject's Drop (which handles object count and object-level overhead), all metrics stay accurate through the full lifecycle.

## See Also

- [bloom-object.md](bloom-object.md) - BloomObject struct, scaling mechanism, FP tightening
- [persistence.md](persistence.md) - RDB save/load format, from_existing usage during restore
- [defrag-metrics.md](defrag-metrics.md) - Defrag of the internal Bloom struct and bit vector
- [../commands/bf-reserve-insert.md](../commands/bf-reserve-insert.md) - BF.RESERVE and BF.INSERT command handling that creates BloomFilter instances
- [../commands/module-configs.md](../commands/module-configs.md) - bloom-use-random-seed and other configs controlling filter creation
