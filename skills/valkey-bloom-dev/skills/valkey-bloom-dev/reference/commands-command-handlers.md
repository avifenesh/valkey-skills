# Command handlers - BF.ADD, BF.MADD, BF.EXISTS, BF.MEXISTS, BF.CARD, BF.INFO

Use when reasoning about read/add command implementations, multi-item variants, auto-creation, or BF.INFO field semantics.

Source: `src/bloom/command_handler.rs`, `src/lib.rs`.

## BF.ADD / BF.MADD - shared handler

Both go through `bloom_filter_add_value(ctx, args, multi: bool)`. `lib.rs` wrappers set `multi=false` for ADD and `multi=true` for MADD.

Arity:

- `BF.ADD key item` - exactly 3.
- `BF.MADD key item [item ...]` - at least 3.

Key opened `writable` via `open_key_writable` + `get_value::<BloomObject>(&BLOOM_TYPE)` (returns `WrongType` on type mismatch). Size validation gated by `!must_obey_client(ctx)`.

## Auto-creation

When the key is `None`, BF.ADD / BF.MADD create with current module config:

- `fp_rate` from `BLOOM_FP_RATE_F64` (Mutex),
- `tightening_ratio` from `BLOOM_TIGHTENING_F64` (Mutex),
- `capacity` from `BLOOM_CAPACITY` (AtomicI64),
- `expansion` from `BLOOM_EXPANSION` (AtomicI64, cast to u32),
- seed `(None, true)` if `BLOOM_USE_RANDOM_SEED`, else `(Some(FIXED_SEED), false)`.

After creation: `set_value(&BLOOM_TYPE, bloom)` + replicate with `reserve_operation: true`. Replication always uses synthetic BF.INSERT (see `commands-replication.md`).

On existing keys, `reserve_operation: false`; verbatim replication fires only when at least one item was new (`add_succeeded == true`).

## `handle_bloom_add` (shared by ADD / MADD / INSERT)

| `multi` | Behavior |
|---------|----------|
| `false` | `bf.add_item(item, validate_size_limit)`. Returns `ValkeyValue::Integer(0)` dup or `Integer(1)` new. Errors -> `ValkeyError::Str`. `add_succeeded` true on new. |
| `true` | Iterate items. Each -> `Integer(0/1)` in a result Vec. First error -> push `ValkeyValue::StaticError` and `break` (remaining items skipped). `add_succeeded` true if any item returned 1. |

`add_succeeded` also gates the `bloom.add` keyspace notification and verbatim replication.

## BF.EXISTS / BF.MEXISTS

Shared `bloom_filter_exists(ctx, args, multi)`. Opened read-only via `open_key`. Missing key returns `Integer(0)` per item (not an error).

`handle_item_exists` -> `val.item_exists(item)` -> `filters.iter().any(|f| f.check(item))`. Scans **all** sub-filters - scaled blooms must check every filter, not just the last.

## BF.CARD

Arity exactly 2. Read-only open. `Some(val)` -> `Integer(val.cardinality())` (sum of `num_items` across filters). `None` -> `Integer(0)`.

## BF.INFO

Arity 2 or 3 (`!(2..=3).contains(&argc)` check). Read-only open. **Unlike BF.EXISTS / BF.CARD, missing key returns `ERR not found` (`utils::NOT_FOUND`)** - only read command that errors on missing keys.

### Field queries (argc == 3)

Field name matched case-insensitively:

| Field | Returns | Notes |
|-------|---------|-------|
| `CAPACITY` | `val.capacity()` | sum across filters |
| `SIZE` | `val.memory_usage() as i64` | |
| `FILTERS` | `val.num_filters() as i64` | |
| `ITEMS` | `val.cardinality()` | |
| `ERROR` | `val.fp_rate()` (Float) | |
| `EXPANSION` | `val.expansion() as i64` or `Null` if 0 | |
| `TIGHTENING` | `val.tightening_ratio()` | scaling filters only |
| `MAXSCALEDCAPACITY` | computed | scaling filters only |

`MAXSCALEDCAPACITY` and `TIGHTENING` on non-scaling filters return `ERR invalid information value`. Unknown field name also returns `invalid information value`.

`MAXSCALEDCAPACITY` calls `calculate_max_scaled_capacity` with `val.starting_capacity()` (first filter's capacity) and `scale_to = -1`.

### Full output (argc == 2)

Interleaved label/value array:

```
Capacity / Size / Number of filters / Number of items inserted / Error rate / Expansion rate
```

For scaling filters, appends `Tightening ratio` and `Max scaled capacity`. Non-scaling: returns `Null` for Expansion rate and omits the two scaling fields. `Max scaled capacity` uses `starting_capacity()`, not total.

## Command registration

From the `valkey_module!` commands block:

| Command | Flags | ACL |
|---------|-------|-----|
| BF.ADD | `write fast deny-oom` | `fast write bloom` |
| BF.MADD | `write fast deny-oom` | `fast write bloom` |
| BF.EXISTS | `readonly fast` | `fast read bloom` |
| BF.MEXISTS | `readonly fast` | `fast read bloom` |
| BF.CARD | `readonly fast` | `fast read bloom` |
| BF.INFO | `readonly fast` | `fast read bloom` |

Key spec `1, 1, 1` (first=1, last=1, step=1). All commands tagged with the custom `bloom` ACL category from `acl_categories`.
