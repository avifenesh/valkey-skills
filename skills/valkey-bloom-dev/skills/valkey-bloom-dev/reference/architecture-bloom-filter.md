# BloomFilter - sub-filter and bloomfilter crate integration

Use when reasoning about the individual sub-filter, the `bloomfilter` crate, seed handling, or per-filter add/check.

Source: `src/bloom/utils.rs`.

## Struct

```rust
#[derive(Serialize, Deserialize)]
pub struct BloomFilter {
    #[serde(serialize_with = "serialize", deserialize_with = "deserialize_boxed_bloom")]
    bloom: Box<bloomfilter::Bloom<[u8]>>,  // bit vec + SipHash keys
    num_items: i64,
    capacity: i64,
}
```

`num_items` / `capacity` are `i64` even though item counts can't exceed u32::MAX in practice - the 128 MB memory cap hits far earlier. Serde wiring uses the crate's `serialize` and a local `deserialize_boxed_bloom` wrapper to produce a `Box<Bloom>`.

## `bloomfilter` crate (3.0.1)

External crate providing:

- `Bloom<[u8]>` over a `Vec<u8>` bit vector.
- SipHash-1-3, 32-byte seed -> two 64-bit SIP keys.
- `new_for_fp_rate(cap, fp)` / `new_for_fp_rate_with_seed(cap, fp, &[u8;32])` - compute optimal bits and hash functions.
- `set(&[u8])` / `check(&[u8])` - hash + bit ops.
- `as_slice()` / `from_slice(&[u8])` - raw bitmap for RDB (the SipHash keys are embedded in the byte stream, so seed is preserved implicitly).
- `to_bytes()` - full state for `COPY`.
- `compute_bitmap_size(cap, fp)` - byte count without allocation.
- `realloc_large_heap_allocated_objects(fn)` - defrag hook for the inner Vec.

## Constructors

| Method | Use |
|--------|-----|
| `with_fixed_seed(fp, cap, &seed)` | scale-out (subsequent filters inherit first filter's seed), replication (SEED arg), fixed-seed mode |
| `with_random_seed(fp, cap)` | first filter only, when `bloom-use-random-seed=true` and no explicit seed |
| `from_existing(bitmap, num_items, capacity)` | RDB load - reconstructs via `Bloom::from_slice`, recovers hasher state from the bitmap bytes |

All three call `bloom_filter_incr_metrics_on_new_create`.

## Seed handling

`FIXED_SEED` in `src/configs.rs` is a compile-time `[u8; 32]` constant. Seed policy is controlled by `bloom-use-random-seed` (default: true):

| Mode | First filter | Sub-filters | Replication (SEED arg) |
|------|--------------|-------------|------------------------|
| Random (default) | `with_random_seed` | `with_fixed_seed(self.seed())` | actual random seed |
| Fixed (`no`) | `with_fixed_seed(FIXED_SEED)` | `with_fixed_seed(self.seed())` | `FIXED_SEED` |

All sub-filters in an object share the first filter's seed. `BloomObject::seed()` delegates to `filters[0].seed()`.

On RDB load, if `is_seed_random == false` and a restored filter's seed differs from the local `FIXED_SEED` constant, load fails with "Object in fixed seed mode, but seed does not match FIXED_SEED." - catches cross-build mismatches.

## Add and check

```rust
pub fn check(&self, item: &[u8]) -> bool { self.bloom.check(item) }
pub fn set(&mut self, item: &[u8])        { self.bloom.set(item) }
```

`set` does not check for existence. Dedup is the caller's job: `BloomObject::add_item` scans all filters before setting, so `num_items` is incremented only on genuinely new items.

## Memory sizing

```rust
pub fn number_of_bytes(&self) -> usize {
    size_of::<BloomFilter>()
      + size_of::<bloomfilter::Bloom<[u8]>>()
      + (self.bloom.len() / 8) as usize   // len() is bits
}

pub fn compute_size(capacity: i64, fp_rate: f64) -> usize {
    size_of::<BloomFilter>()
      + size_of::<bloomfilter::Bloom<[u8]>>()
      + bloomfilter::Bloom::<[u8]>::compute_bitmap_size(capacity as usize, fp_rate)
}
```

`compute_size` drives `validate_size_before_create` / `validate_size_before_scaling` pre-allocation checks.

## `create_copy_from` (COPY command)

`BloomFilter::from_existing(&bf.bloom.to_bytes(), bf.num_items, bf.capacity)` - serializes then reconstructs. Produces an independent heap allocation.

## Drop

Decrements four counters: `BLOOM_NUM_FILTERS_ACROSS_OBJECTS`, `BLOOM_OBJECT_TOTAL_MEMORY_BYTES` (by `number_of_bytes()`), `BLOOM_NUM_ITEMS_ACROSS_OBJECTS` (by `num_items`), `BLOOM_CAPACITY_ACROSS_OBJECTS` (by `capacity`). Paired with `BloomObject::Drop` (object count + overhead), keeps all seven metrics consistent through the lifecycle.
