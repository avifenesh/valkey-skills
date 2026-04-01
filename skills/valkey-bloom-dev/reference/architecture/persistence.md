# Persistence - RDB, AOF, and Bincode Serialization

Use when understanding how bloom objects are saved to RDB, loaded from RDB, rewritten to AOF, serialized with bincode for BF.LOAD, or how the COPY callback works.

Source: `src/wrapper/bloom_callback.rs`, `src/bloom/data_type.rs`, `src/bloom/utils.rs`

## Contents

- Version Constants (line 21)
- RDB Save Format (line 29)
- RDB Load and Validation (line 64)
- AOF Rewrite via BF.LOAD (line 104)
- Bincode Encode (line 125)
- Bincode Decode (line 147)
- Copy Callback (line 171)
- Auxiliary Data (line 190)
- Data Type Registration (line 204)

---

## Version Constants

Two version constants control serialization compatibility:

**`BLOOM_TYPE_ENCODING_VERSION`** (line 16 of `data_type.rs`): Set to `1`. This is the RDB encoding version passed to `ValkeyType::new`. During RDB load, if the file's `encver` exceeds this value, the load is rejected with a warning.

**`BLOOM_OBJECT_VERSION`** (line 13 of `data_type.rs`): Set to `1`. This is the bincode serialization version prepended to the byte stream in `encode_object`. Must be incremented when the `BloomObject` struct changes.

## RDB Save Format

The `bloom_rdb_save` function (line 27 of `bloom_callback.rs`) writes each BloomObject field-by-field:

```
[num_filters: u64]
[expansion: u64]
[fp_rate: f64]
[tightening_ratio: f64]
[is_seed_random: u64]    // 1 = true, 0 = false
--- per filter (repeated num_filters times) ---
[capacity: u64]
[num_items: u64]          // ONLY for the last filter
[bitmap: string_buffer]   // raw bit vector bytes from bloom.as_slice()
```

The `num_items` optimization: only the last filter's `num_items` is stored. For all previous filters, `num_items` is assumed equal to `capacity` (they are full - that's why scaling created the next filter). This saves space in RDB for objects with many sub-filters.

The bitmap is written via `RedisModule_SaveStringBuffer` as raw bytes. The bitmap includes the SipHash keys embedded by the bloomfilter crate, so seed information is preserved implicitly without a separate seed field in RDB.

Key implementation detail from `bloom_rdb_save`:

```rust
let mut filter_list_iter = filter_list.iter().peekable();
while let Some(filter) = filter_list_iter.next() {
    raw::save_unsigned(rdb, filter.capacity() as u64);
    if filter_list_iter.peek().is_none() {
        // Only save num_items for the last filter
        raw::save_unsigned(rdb, filter.num_items() as u64);
    }
    let bitmap = bloom.as_slice();
    RedisModule_SaveStringBuffer(rdb, bitmap.as_ptr(), bitmap.len());
}
```

## RDB Load and Validation

The `load_from_rdb` function (line 58 of `data_type.rs`) implements the `ValkeyDataType` trait. It performs extensive validation during restore:

**Step 1 - Version check**:

```rust
if encver > BLOOM_TYPE_ENCODING_VERSION {
    log_warning("Cannot load bloomfltr data type of version {encver}...");
    return None;
}
```

**Step 2 - Read header fields**: `num_filters`, `expansion`, `fp_rate`, `tightening_ratio`, `is_seed_random` (converted from u64 to bool).

**Step 3 - Reconstruct filters** in a loop from 0 to `num_filters`:

For each filter:
1. Read `capacity`
2. Calculate the expected FP rate for this filter index: `calculate_fp_rate(fp_rate, i, tightening_ratio)`. If FP degrades to zero, abort.
3. Compute projected filter size via `BloomFilter::compute_size(capacity, fp_rate)` and validate cumulative object size against the memory limit. If exceeded, abort with "Object larger than the allowed memory limit."
4. Read `num_items` - only for the last filter (`i == num_filters - 1`). For all others, set `num_items = capacity`.
5. Read the bitmap via `load_string_buffer`
6. Reconstruct: `BloomFilter::from_existing(bitmap, num_items, capacity)`

**Step 4 - Fixed seed validation** (line 123):

```rust
if !is_seed_random && filter.seed() != configs::FIXED_SEED {
    log_warning("Object in fixed seed mode, but seed does not match FIXED_SEED.");
    return None;
}
```

This catches the case where a fixed-seed object was created on a node with a different `FIXED_SEED` constant, preventing silent data corruption.

**Step 5 - Assemble**: `BloomObject::from_existing(expansion, fp_rate, tightening_ratio, is_seed_random, filters)`.

The `filters` vec is initialized with `Vec::with_capacity(1)` to match the same expansion pattern as normal creation (capacity starts at 1, then grows as elements are pushed).

## AOF Rewrite via BF.LOAD

The `bloom_aof_rewrite` function (line 67 of `bloom_callback.rs`) emits a `BF.LOAD` command containing the entire BloomObject as a bincode-serialized blob:

```rust
let hex = match filter.encode_object() {
    Ok(val) => val,
    Err(err) => {
        log_io_error(aof, ValkeyLogLevel::Warning, err.as_str());
        return;
    }
};
let cmd = CString::new("BF.LOAD").unwrap();
let fmt = CString::new("sb").unwrap();
RedisModule_EmitAOF(aof, cmd.as_ptr(), fmt.as_ptr(), key, hex.as_ptr(), hex.len());
```

The format string `"sb"` means: `s` = RedisModuleString (the key), `b` = binary buffer (the serialized bytes). The `BF.LOAD` command handler on the receiving end calls `decode_object` to reconstruct the BloomObject.

Unlike RDB save which writes fields individually, AOF rewrite serializes the entire struct in one shot via bincode. This is simpler but produces a larger payload since it includes serde metadata.

## Bincode Encode

The `encode_object` method (line 372 of `utils.rs`) serializes a BloomObject for BF.LOAD:

```rust
pub fn encode_object(&self) -> Result<Vec<u8>, BloomError> {
    match bincode::serialize(self) {
        Ok(vec) => {
            let mut final_vec = Vec::with_capacity(1 + vec.len());
            final_vec.push(BLOOM_OBJECT_VERSION);  // Version byte prefix
            final_vec.extend(vec);
            Ok(final_vec)
        }
        Err(_) => Err(BloomError::EncodeBloomFilterFailed),
    }
}
```

The version byte (`BLOOM_OBJECT_VERSION = 1`) is prepended before the bincode data. This allows future struct changes to be handled by version-specific deserialization logic.

The `BloomObject` derives `Serialize` and `Deserialize`. The `BloomFilter`'s `bloom` field uses custom serde functions from the bloomfilter crate to handle the `Bloom<[u8]>` type.

## Bincode Decode

The `decode_object` function (line 408 of `utils.rs`) handles BF.LOAD deserialization:

```rust
pub fn decode_object(
    decoded_bytes: &[u8],
    validate_size_limit: bool,
) -> Result<BloomObject, BloomError>
```

**Version dispatch**: Reads the first byte as the version number, then matches on it. Currently only version 1 is supported. Unknown versions return `DecodeUnsupportedVersion`. Empty input returns `DecodeBloomFilterFailed`.

**Version 1 deserialization**: Deserializes bytes[1..] via bincode into `(u32, f64, f64, bool, Vec<Box<BloomFilter>>)` - matching the BloomObject field order.

**Validation** after deserialization:
- Expansion range: `0..=BLOOM_EXPANSION_MAX`
- FP rate: `(BLOOM_FP_RATE_MIN, BLOOM_FP_RATE_MAX)` exclusive
- Tightening ratio: `(BLOOM_TIGHTENING_RATIO_MIN, BLOOM_TIGHTENING_RATIO_MAX)` exclusive
- Filter count: less than `BLOOM_NUM_FILTERS_PER_OBJECT_LIMIT_MAX`
- Total memory: checked against `bloom-memory-usage-limit` when `validate_size_limit` is true

**Metrics updates**: For each deserialized filter, `bloom_filter_incr_metrics_on_new_create` and `BLOOM_NUM_ITEMS_ACROSS_OBJECTS` are updated. Then `bloom_object_incr_metrics_on_new_create` is called for the object itself.

## Copy Callback

The `bloom_copy` function (line 117 of `bloom_callback.rs`) handles the Valkey `COPY` command:

```rust
pub unsafe extern "C" fn bloom_copy(
    _from_key: *mut RedisModuleString,
    _to_key: *mut RedisModuleString,
    value: *const c_void,
) -> *mut c_void {
    let curr_item = &*value.cast::<BloomObject>();
    let new_item = BloomObject::create_copy_from(curr_item);
    let bb = Box::new(new_item);
    Box::into_raw(bb).cast::<libc::c_void>()
}
```

Delegates to `BloomObject::create_copy_from`, which deep-copies all filters via `BloomFilter::create_copy_from`. Each filter serializes its bloom to bytes and reconstructs, producing fully independent heap allocations.

## Auxiliary Data

The `bloom_aux_load` callback (line 94 of `bloom_callback.rs`) handles auxiliary (out-of-keyspace) data from RDB files:

```rust
pub unsafe extern "C" fn bloom_aux_load(
    rdb: *mut raw::RedisModuleIO, _encver: c_int, _when: c_int,
) -> c_int {
    bloom::data_type::bloom_rdb_aux_load(rdb)
}
```

The implementation in `data_type.rs` (line 156) logs at notice level "Ignoring AUX fields during RDB load" and returns `Status::Ok`. The `aux_save` and `aux_save2` callbacks are set to `None` since the module has no auxiliary data to persist.

## Data Type Registration

The `BLOOM_TYPE` static in `data_type.rs` (line 18) registers all callbacks:

```rust
pub static BLOOM_TYPE: ValkeyType = ValkeyType::new(
    "bloomfltr",
    BLOOM_TYPE_ENCODING_VERSION,
    raw::RedisModuleTypeMethods { ... },
);
```

Type name is `"bloomfltr"` (9 characters, the Valkey maximum). Callbacks wired to implementations:
- `rdb_save`, `rdb_load`, `aof_rewrite`, `digest` - persistence and integrity
- `mem_usage`, `free`, `free_effort` - memory management
- `copy`, `defrag`, `aux_load` - replication and maintenance

The `digest` callback (line 130 of `bloom_callback.rs`) implements `DEBUG DIGEST` by hashing `expansion`, `fp_rate`, `tightening_ratio`, `is_seed_random`, and each filter's raw bitmap, `num_items`, and `capacity` via the `Digest` API. The `free` callback (line 104) drops the BloomObject box, triggering the `Drop` impls for both BloomObject and its BloomFilter children.

Callbacks set to `None`: `unlink`, `mem_usage2`, `free_effort2`, `unlink2`, `copy2`, `aux_save`, `aux_save2`. The version 1 variants are used where both exist.