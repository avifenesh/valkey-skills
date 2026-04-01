# BF.RESERVE, BF.INSERT, and BF.LOAD

Use when understanding explicit bloom creation, complex argument parsing in BF.INSERT, replication-only arguments (TIGHTENING, SEED), VALIDATESCALETO validation, or the BF.LOAD AOF rewrite path.

Source: `src/bloom/command_handler.rs`

## Contents

- BF.RESERVE (line 22)
- BF.INSERT (line 44)
- BF.INSERT Argument Parsing (line 52)
- Replication-Only Arguments (line 74)
- VALIDATESCALETO Validation (line 90)
- NOCREATE Behavior (line 106)
- BF.INSERT Object Creation vs Existing (line 121)
- BF.LOAD (line 129)
- Error Summary (line 151)
- See Also (line 174)

---

## BF.RESERVE

`bloom_filter_reserve` creates a bloom object with explicit parameters. Syntax: `BF.RESERVE key fp_rate capacity [EXPANSION exp | NONSCALING]`.

**Arity**: 4 to 6 args. The function checks `!(4..=6).contains(&argc)`.

**Argument parsing order**:

1. **key** - filter name at index 1
2. **fp_rate** - parsed as f64, must satisfy `0 < fp_rate < 1` (exclusive on both ends). Two separate error paths: out-of-range values get `ERR (0 < error rate range < 1)`, unparseable strings get `ERR bad error rate`.
3. **capacity** - parsed as i64, must be in `BLOOM_CAPACITY_MIN..=BLOOM_CAPACITY_MAX` (1 to i64::MAX). Zero specifically returns `ERR (capacity should be larger than 0)`. Other invalid values return `ERR bad capacity`.
4. **Optional trailing argument** (argc > 4):
   - `NONSCALING` (argc must be 5) - sets expansion to 0
   - `EXPANSION <value>` (argc must be 6) - parsed as u32, range `BLOOM_EXPANSION_MIN..=BLOOM_EXPANSION_MAX` (1 to u32::MAX). Invalid values return `ERR bad expansion`.
   - Anything else returns `ERR ERROR`

**Key existence check**: If the key already exists with a bloom object, returns `ERR item exists`. BF.RESERVE never overwrites. Returns `WrongType` if the key holds a non-bloom type.

**Object creation**: Uses current config values for tightening ratio and seed mode. Calls `BloomObject::new_reserved` with size validation gated on `!must_obey_client(ctx)`. After storing, replicates with `reserve_operation: true` and no items.

**Default expansion**: When neither EXPANSION nor NONSCALING is provided (argc == 4), uses `configs::BLOOM_EXPANSION` (default 2).

## BF.INSERT

`bloom_filter_insert` is the most complex command handler. Syntax: `BF.INSERT key [ERROR fp] [CAPACITY cap] [EXPANSION exp] [NOCREATE] [NONSCALING] [TIGHTENING ratio] [SEED bytes] [VALIDATESCALETO cap] ITEMS item [item ...]`.

**Minimum arity**: 2 args (`BF.INSERT key`). Unlike BF.RESERVE, BF.INSERT can be called without items - it can create an empty bloom object.

**Default values**: All optional parameters start with current module config defaults (fp_rate, tightening_ratio, capacity, expansion, seed mode). Explicit arguments override these.

## BF.INSERT Argument Parsing

Arguments are parsed in a `while idx < argc` loop with case-insensitive keyword matching (via `to_uppercase()`):

| Keyword | Expects Value | Parsing |
|---------|--------------|---------|
| `ERROR` | Yes | f64, range `(0, 1)` exclusive |
| `TIGHTENING` | Yes | f64, range `(0, 1)` exclusive; replication-internal |
| `CAPACITY` | Yes | i64, range `1..=i64::MAX`; zero returns `ERR (capacity should be larger than 0)` |
| `SEED` | Yes | Exactly 32 bytes (raw `[u8; 32]`); replication-internal |
| `NOCREATE` | No | Sets `nocreate = true` |
| `NONSCALING` | No | Sets `expansion = 0` |
| `EXPANSION` | Yes | u32, range `1..=u32::MAX` |
| `VALIDATESCALETO` | Yes | i64, range `1..=i64::MAX`; zero returns `ERR (capacity should be larger than 0)` |
| `ITEMS` | Starts items | Increments idx, sets `items_provided = true`, breaks loop |

**ITEMS sentinel**: The `ITEMS` keyword breaks out of the option parsing loop. All remaining arguments after `ITEMS` are treated as items to add. If `ITEMS` is provided but no items follow (`idx == argc && items_provided`), returns `WrongArity`.

**Unknown arguments**: Any unrecognized keyword returns `ERR unknown argument received`.

**Value-expecting keywords**: Each checks `idx >= (argc - 1)` to ensure a value follows. Missing values return `WrongArity`.

## Replication-Only Arguments

**TIGHTENING** and **SEED** are documented in source comments as replication-internal:

```rust
"TIGHTENING" => {
    // Note: This argument is only supported on replicated commands since primary nodes
    // replicate bloom objects deterministically using every global bloom config/property.
```

When the primary creates a bloom object (via BF.ADD, BF.RESERVE, or BF.INSERT), it replicates the creation as `BF.INSERT ... TIGHTENING <ratio> SEED <32bytes> ...`. This ensures replicas use the exact same tightening ratio and seed as the primary, regardless of the replica's local config values.

**SEED parsing**: The raw bytes from the ValkeyString are converted to `[u8; 32]` via `try_into()`. If the slice is not exactly 32 bytes, returns `ERR invalid seed`. The `is_seed_random` flag is derived by comparing against `FIXED_SEED` - if different, it is considered random.

**TIGHTENING parsing**: Parsed as f64 with range `(0, 1)` exclusive. Out-of-range values return `ERR (0 < tightening ratio range < 1)`. Unparseable strings return `ERR bad tightening ratio`.

## VALIDATESCALETO Validation

`VALIDATESCALETO` is a user-facing argument that validates whether a bloom object can scale to a target capacity before creating it. It is a pre-creation check, not a runtime limit.

After all arguments are parsed, if `validate_scale_to` is set:

1. Check that `expansion != 0` - combining NONSCALING with VALIDATESCALETO returns `ERR cannot use NONSCALING and VALIDATESCALETO options together`.

2. Call `BloomObject::calculate_max_scaled_capacity(capacity, fp_rate, scale_to, tightening_ratio, expansion)` which simulates filter scaling to determine if the target capacity is reachable.

3. Two failure modes from `calculate_max_scaled_capacity`:
   - FP rate degrades to zero before reaching target: `ERR provided VALIDATESCALETO causes false positive to degrade to 0`
   - Memory limit exceeded before reaching target: `ERR provided VALIDATESCALETO causes bloom object to exceed memory limit`

This argument is not replicated - it is validated on the primary before object creation only.

## NOCREATE Behavior

When `nocreate = true` and the key does not exist, BF.INSERT returns `ERR not found` instead of creating a new bloom object. This is checked in the `None` branch of the key existence match:

```rust
None => {
    if nocreate {
        return Err(ValkeyError::Str(utils::NOT_FOUND));
    }
    // ... create new bloom
}
```

When the key exists, NOCREATE has no effect - items are added normally.

## BF.INSERT Object Creation vs Existing

**Existing key** (`Some` branch): Items are added to the existing bloom. Option arguments like CAPACITY and ERROR are ignored for existing objects. Replication uses `reserve_operation: false` (verbatim replication only when at least one item was new). The bloom object's properties from creation time are used in `ReplicateArgs`, not the arguments from the current command.

**New key** (`None` branch, no NOCREATE): Creates with the parsed parameters (or defaults). Size validation is gated by `!must_obey_client(ctx)`. After calling `BloomObject::new_reserved`, items are added via `handle_bloom_add` with `multi: true` (BF.INSERT always uses multi mode for items). After `set_value`, replicates with `reserve_operation: true`.

The response is always a multi-result array since `handle_bloom_add` is called with `multi: true`, returning `ValkeyValue::Array` of integer results (1 for new, 0 for duplicate). When no ITEMS are provided and the key is new, the response is an empty array.

## BF.LOAD

`bloom_filter_load` is an internal command used by AOF rewrite, not intended for direct user invocation. Syntax: `BF.LOAD key data`.

**Arity**: Exactly 3 args.

**Command flags**: `write deny-oom` (no `fast` flag, unlike other write commands). ACL: `write bloom`.

**Key check**: If the key already exists, returns `BUSYKEY Target key name already exists.` (the `utils::KEY_EXISTS` constant). Returns `WrongType` if the key holds a non-bloom type.

**Deserialization path**: The data argument is the raw bytes from `BloomObject::encode_object`:

1. Calls `BloomObject::decode_object(&hex, validate_size_limit)`
2. `decode_object` reads byte 0 as the version (must be 1)
3. Remaining bytes are bincode-deserialized into `(u32, f64, f64, bool, Vec<Box<BloomFilter>>)`
4. Validates: expansion range (0 to u32::MAX), fp_rate range, tightening_ratio range, filter count (< i32::MAX), total memory size
5. On failure: `ERR bloom object decoding failed` or `ERR bloom object decoding failed. Unsupported version`

**Size validation**: Gated by `!must_obey_client(ctx)`, same as other write commands. Replicas skip size validation.

**Replication**: After successful load, replicates with `reserve_operation: true`. The replicated form is a synthetic `BF.INSERT` with full bloom object properties (capacity, fp_rate, tightening_ratio, seed, expansion). The data argument is included in the replicated items list, so the replica creates the bloom structure via BF.INSERT rather than BF.LOAD.

## Error Summary

| Command | Error | Condition |
|---------|-------|-----------|
| BF.RESERVE | `ERR item exists` | Key already has a bloom object |
| BF.RESERVE | `ERR bad error rate` | fp_rate not parseable as f64 |
| BF.RESERVE | `ERR (0 < error rate range < 1)` | fp_rate out of range |
| BF.RESERVE | `ERR bad capacity` | capacity not parseable |
| BF.RESERVE | `ERR (capacity should be larger than 0)` | capacity == 0 |
| BF.RESERVE | `ERR bad expansion` | expansion not parseable or out of range |
| BF.RESERVE | `ERR ERROR` | Unknown trailing argument |
| BF.INSERT | `ERR not found` | NOCREATE and key missing |
| BF.INSERT | `ERR unknown argument received` | Unrecognized option keyword |
| BF.INSERT | `ERR invalid seed` | SEED not exactly 32 bytes |
| BF.INSERT | `ERR bad tightening ratio` | TIGHTENING not parseable as f64 |
| BF.INSERT | `ERR (0 < tightening ratio range < 1)` | TIGHTENING out of range |
| BF.INSERT | `ERR cannot use NONSCALING and VALIDATESCALETO options together` | Both specified |
| BF.INSERT | `ERR provided VALIDATESCALETO causes false positive to degrade to 0` | Scale target unreachable (FP) |
| BF.INSERT | `ERR provided VALIDATESCALETO causes bloom object to exceed memory limit` | Scale target unreachable (mem) |
| BF.LOAD | `BUSYKEY Target key name already exists.` | Key already exists |
| BF.LOAD | `ERR bloom object decoding failed` | Bincode deserialization failure |
| BF.LOAD | `ERR bloom object decoding failed. Unsupported version` | Version byte != 1 |

## See Also

- [command-handlers](command-handlers.md) - BF.ADD, BF.MADD, BF.EXISTS, BF.MEXISTS, BF.CARD, BF.INFO
- [replication](replication.md) - How creation replicates as BF.INSERT with SEED/TIGHTENING
- [bloom-object](../architecture/bloom-object.md) - BloomObject internals, encode/decode, scaling
- [persistence](../architecture/persistence.md) - RDB save/load, AOF rewrite via BF.LOAD
