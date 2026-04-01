# Command Handlers - BF.ADD, BF.MADD, BF.EXISTS, BF.MEXISTS, BF.CARD, BF.INFO

Use when understanding read and add command implementations, multi-item variants, auto-creation behavior, cardinality queries, or BF.INFO field introspection.

Source: `src/bloom/command_handler.rs`, `src/bloom/utils.rs`, `src/lib.rs`

## Contents

- BF.ADD and BF.MADD (line 22)
- Auto-Creation Behavior (line 41)
- handle_bloom_add Helper (line 55)
- BF.EXISTS and BF.MEXISTS (line 65)
- BF.CARD (line 81)
- BF.INFO (line 94)
- BF.INFO Field Queries (line 105)
- BF.INFO Full Output (line 124)
- Command Registration (line 146)

---

## BF.ADD and BF.MADD

Both commands share the `bloom_filter_add_value` function, differentiated by a `multi: bool` parameter. The entry points in `lib.rs` are thin wrappers:

```rust
fn bloom_add_command(ctx: &Context, args: Vec<ValkeyString>) -> ValkeyResult {
    command_handler::bloom_filter_add_value(ctx, &args, false)  // single item
}
fn bloom_madd_command(ctx: &Context, args: Vec<ValkeyString>) -> ValkeyResult {
    command_handler::bloom_filter_add_value(ctx, &args, true)   // multi item
}
```

**Arity checks**: BF.ADD requires exactly 3 args (`BF.ADD key item`). BF.MADD requires at least 3 (`BF.MADD key item [item ...]`). The check `(!multi && argc != 3) || argc < 3` enforces both.

**Key opening**: Uses `ctx.open_key_writable(filter_name)` since these are mutative. Calls `get_value::<BloomObject>(&BLOOM_TYPE)` and returns `WrongType` on type mismatch.

**Size validation**: Skipped on replicated commands via `!must_obey_client(ctx)`. Replicas must accept whatever the primary sends regardless of local memory limits.

## Auto-Creation Behavior

When the key does not exist (the `None` branch), BF.ADD and BF.MADD create a new bloom object using current module config defaults:

- `fp_rate` from `BLOOM_FP_RATE_F64` (Mutex lock)
- `tightening_ratio` from `BLOOM_TIGHTENING_F64` (Mutex lock)
- `capacity` from `BLOOM_CAPACITY` (AtomicI64)
- `expansion` from `BLOOM_EXPANSION` (AtomicI64, cast to u32)
- Seed: random `(None, true)` if `BLOOM_USE_RANDOM_SEED` is true, else `(Some(FIXED_SEED), false)`

After creation, the new bloom object is stored with `filter_key.set_value(&BLOOM_TYPE, bloom)`. The replication call passes `reserve_operation: true` so the creation is replicated deterministically as a `BF.INSERT` with full properties.

When the key already exists (the `Some` branch), items are added to the existing bloom and replication passes `reserve_operation: false`, causing verbatim replication only when at least one item was new (`add_succeeded == true`).

## handle_bloom_add Helper

This private function handles item insertion for BF.ADD, BF.MADD, and BF.INSERT. It branches on the `multi` parameter:

**Single mode** (`multi: false`): Calls `bf.add_item(item, validate_size_limit)` on the one item at `item_idx`. Returns `ValkeyValue::Integer(0)` for duplicate, `ValkeyValue::Integer(1)` for new. Sets `add_succeeded = true` only on new insertions. Errors propagate as `ValkeyError::Str`.

**Multi mode** (`multi: true`): Iterates from `item_idx` to `argc`, collecting results into a `Vec`. Each item gets `ValkeyValue::Integer(0|1)`. On error (e.g., non-scaling filter full, memory limit exceeded, max filters reached), the error is pushed as `ValkeyValue::StaticError` and iteration stops with `break` - remaining items are not processed.

The `add_succeeded` flag is set to true if any item returned 1. This flag controls whether a `bloom.add` keyspace notification fires and whether verbatim replication occurs.

## BF.EXISTS and BF.MEXISTS

Both share `bloom_filter_exists`, differentiated by `multi: bool`. The pattern mirrors add but is read-only:

```rust
let filter_key = ctx.open_key(filter_name);  // read-only open
```

**Single mode**: Returns `ValkeyValue::Integer(1)` if found, `0` otherwise. Non-existent keys return `0` (not an error).

**Multi mode**: Collects results into a `Vec<ValkeyValue>`. Each item independently returns 0 or 1.

The standalone `handle_item_exists` function calls `val.item_exists(item)`, which runs `self.filters.iter().any(|filter| filter.check(item))` - scanning all sub-filters in the bloom object. This means existence checks search every filter in a scaled bloom, not just the last one.

**Key behavior**: When the key does not exist at all, the function returns `ValkeyValue::Integer(0)` for each item rather than an error. This matches Valkey convention where checking membership on a non-existent set returns 0.

## BF.CARD

`bloom_filter_card` is the simplest command. Requires exactly 2 args (`BF.CARD key`).

```rust
match value {
    Some(val) => Ok(ValkeyValue::Integer(val.cardinality())),
    None => Ok(ValkeyValue::Integer(0)),
}
```

`cardinality()` in `utils.rs` sums `num_items` across all sub-filters in the bloom object. Like BF.EXISTS, a non-existent key returns 0 rather than an error. Opens the key read-only with `ctx.open_key`.

## BF.INFO

`bloom_filter_info` handles two modes based on argument count:

- `BF.INFO key` (argc == 2) - returns all fields
- `BF.INFO key <field>` (argc == 3) - returns a single field

Unlike BF.CARD and BF.EXISTS, a non-existent key returns `ERR not found` (`utils::NOT_FOUND`). This is the only read command that errors on missing keys.

Arity: exactly 2 or 3 args via `!(2..=3).contains(&argc)`. Opens key read-only.

## BF.INFO Field Queries

When a specific field is requested (argc == 3), the field name is matched case-insensitively:

| Field | Return Value | Notes |
|-------|-------------|-------|
| `CAPACITY` | `val.capacity()` | Sum across all sub-filters |
| `SIZE` | `val.memory_usage() as i64` | Total bytes including all allocations |
| `FILTERS` | `val.num_filters() as i64` | Number of sub-filters |
| `ITEMS` | `val.cardinality()` | Total items across all sub-filters |
| `ERROR` | `val.fp_rate()` | Configured false positive rate (Float) |
| `TIGHTENING` | `val.tightening_ratio()` | Only available when `expansion > 0` |
| `EXPANSION` | `val.expansion() as i64` | Returns `Null` when expansion == 0 (non-scaling) |
| `MAXSCALEDCAPACITY` | calculated | Only available when `expansion > 0` |

**MAXSCALEDCAPACITY** calls `BloomObject::calculate_max_scaled_capacity` with `val.starting_capacity()` (first filter's capacity, not the total) and `scale_to: -1` (meaning no target limit), simulating scale-out until memory or FP rate limits are reached. Only valid for scaling filters.

**TIGHTENING** and **MAXSCALEDCAPACITY** return `ERR invalid information value` when queried on non-scaling filters (expansion == 0). The catch-all `_ =>` branch returns the same error for unknown field names.

## BF.INFO Full Output

When called without a field (argc == 2), returns an interleaved array of label/value pairs:

```
Capacity: <total capacity>
Size: <memory bytes>
Number of filters: <count>
Number of items inserted: <cardinality>
Error rate: <fp_rate>
Expansion rate: <expansion or null>
```

For scaling filters (expansion > 0), two additional fields are appended:

```
Tightening ratio: <ratio>
Max scaled capacity: <max_capacity>
```

The max scaled capacity calculation also uses `val.starting_capacity()` (first filter's capacity), not the total. Non-scaling filters omit the tightening and max capacity fields entirely and return `Null` for expansion rate.

## Command Registration

All commands are registered in the `valkey_module!` macro in `lib.rs`:

| Command | Flags | ACL |
|---------|-------|-----|
| BF.ADD | `write fast deny-oom` | `fast write bloom` |
| BF.MADD | `write fast deny-oom` | `fast write bloom` |
| BF.EXISTS | `readonly fast` | `fast read bloom` |
| BF.MEXISTS | `readonly fast` | `fast read bloom` |
| BF.CARD | `readonly fast` | `fast read bloom` |
| BF.INFO | `readonly fast` | `fast read bloom` |

All commands use key arguments `1, 1, 1` (first-key=1, last-key=1, key-step=1). All mutative commands include the `bloom` ACL category defined in the module's `acl_categories` block.