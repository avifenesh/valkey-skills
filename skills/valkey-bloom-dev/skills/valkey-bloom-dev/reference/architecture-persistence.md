# Persistence - RDB, AOF, bincode

Use when reasoning about RDB save/load, AOF rewrite, bincode serialization, or the COPY callback.

Source: `src/wrapper/bloom_callback.rs`, `src/bloom/data_type.rs`, `src/bloom/utils.rs`.

## Versions

- `BLOOM_TYPE_ENCODING_VERSION = 1` - RDB `encver` passed to `ValkeyType::new`. Load rejects `encver > 1`.
- `BLOOM_OBJECT_VERSION = 1` - byte-prefix on bincode streams from `encode_object`. Bump when `BloomObject` struct layout changes.

Both live in `src/bloom/data_type.rs`.

## RDB save format (`bloom_rdb_save`)

```
[num_filters: u64]
[expansion: u64]
[fp_rate: f64]
[tightening_ratio: f64]
[is_seed_random: u64]   // 1 = true, 0 = false
--- per filter ---
[capacity: u64]
[num_items: u64]        // ONLY for the last filter
[bitmap: string_buffer] // raw bits from bloom.as_slice()
```

**num_items optimization**: only the last filter stores it; prior filters are assumed full (`num_items = capacity`). That's how scaling got there.

Bitmap bytes carry the SipHash keys (embedded by the crate's serialization), so no separate seed field is needed per filter in RDB.

## RDB load (`load_from_rdb` - `ValkeyDataType` trait)

1. `encver > BLOOM_TYPE_ENCODING_VERSION` -> log + return `None`.
2. Read header: `num_filters`, `expansion`, `fp_rate`, `tightening_ratio`, `is_seed_random`.
3. For each filter `i`:
   - Read `capacity`.
   - Compute this filter's FP rate via `calculate_fp_rate(fp_rate, i, tightening_ratio)`. Degrades to 0 -> abort.
   - Project size via `BloomFilter::compute_size`; cumulative check against memory limit -> abort if over.
   - Read `num_items` only when `i == num_filters - 1`; else `num_items = capacity`.
   - Read bitmap via `load_string_buffer`.
   - `BloomFilter::from_existing(bitmap, num_items, capacity)`.
4. If `!is_seed_random`, each restored `filter.seed() != FIXED_SEED` aborts with "Object in fixed seed mode, but seed does not match FIXED_SEED." (catches cross-build mismatches - different `FIXED_SEED` at compile time would silently corrupt data).
5. `BloomObject::from_existing(...)`. `filters` starts at `Vec::with_capacity(1)` to match normal-creation allocation growth.

## AOF rewrite via BF.LOAD (`bloom_aof_rewrite`)

Emits a synthetic `BF.LOAD <key> <bincode_bytes>` using format string `"sb"` (`s`=ValkeyString key, `b`=binary buffer). The receiver decodes via `decode_object`.

AOF uses one-shot bincode (larger payload, simpler) - RDB writes fields individually (smaller, faster to stream). Important: **AOF emits BF.LOAD, replication emits synthetic BF.INSERT** (see `commands-replication.md`). Different paths.

## Bincode encode / decode

```rust
pub fn encode_object(&self) -> Result<Vec<u8>, BloomError> {
    // [BLOOM_OBJECT_VERSION byte] + bincode::serialize(self)
}
```

`decode_object(bytes, validate_size_limit)`:

- `bytes[0]` = version. Empty -> `DecodeBloomFilterFailed`. Unknown -> `DecodeUnsupportedVersion`.
- Version 1: bincode-deserialize `bytes[1..]` into `(u32, f64, f64, bool, Vec<Box<BloomFilter>>)` (the `BloomObject` field tuple).
- Post-decode validation:
  - `expansion` in `0..=BLOOM_EXPANSION_MAX`
  - `fp_rate` in exclusive `(BLOOM_FP_RATE_MIN, BLOOM_FP_RATE_MAX)`
  - `tightening_ratio` in exclusive `(BLOOM_TIGHTENING_RATIO_MIN, BLOOM_TIGHTENING_RATIO_MAX)`
  - Filter count `< BLOOM_NUM_FILTERS_PER_OBJECT_LIMIT_MAX` (`i32::MAX`)
  - Total memory under limit iff `validate_size_limit`.
- Metrics: per filter `bloom_filter_incr_metrics_on_new_create` + `BLOOM_NUM_ITEMS_ACROSS_OBJECTS`; then `bloom_object_incr_metrics_on_new_create`.

## COPY callback (`bloom_copy`)

`unsafe extern "C"` wrapper that delegates to `BloomObject::create_copy_from`. Each `BloomFilter` deep-copies via `create_copy_from` (serialize + reconstruct), giving fully independent heap allocations.

## AUX data

`bloom_aux_load` -> `bloom_rdb_aux_load` logs "Ignoring AUX fields during RDB load" at notice and returns `Status::Ok`. `aux_save` / `aux_save2` are `None` - the module has no out-of-keyspace data.

## Data type registration

```rust
pub static BLOOM_TYPE: ValkeyType = ValkeyType::new(
    "bloomfltr",                  // 9 chars - module type-name max
    BLOOM_TYPE_ENCODING_VERSION,  // 1
    raw::RedisModuleTypeMethods { ... },
);
```

Callbacks wired: `rdb_save`, `rdb_load`, `aof_rewrite`, `digest`, `mem_usage`, `free`, `free_effort`, `copy`, `defrag`, `aux_load`. Unwired (`None`): `unlink`, `mem_usage2`, `free_effort2`, `unlink2`, `copy2`, `aux_save`, `aux_save2`.

`digest` feeds `DEBUG DIGEST-VALUE`: hashes `expansion`, `fp_rate`, `tightening_ratio`, `is_seed_random`, then each filter's raw bitmap, `num_items`, `capacity`. `free` drops the `BloomObject` box (triggers both `Drop` impls).
