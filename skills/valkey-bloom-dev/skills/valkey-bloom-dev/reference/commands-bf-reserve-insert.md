# BF.RESERVE, BF.INSERT, BF.LOAD

Use when reasoning about explicit creation, BF.INSERT argument parsing, replication-only args (SEED / TIGHTENING), VALIDATESCALETO, or the AOF-only BF.LOAD.

Source: `src/bloom/command_handler.rs`.

## BF.RESERVE

`BF.RESERVE key fp_rate capacity [EXPANSION exp | NONSCALING]`. Arity 4 to 6 (`!(4..=6).contains(&argc)`).

Parsing order and errors:

- **key** - index 1.
- **fp_rate** - f64, strict `(0, 1)`. Unparseable: `ERR bad error rate`. Out of range: `ERR (0 < error rate range < 1)`.
- **capacity** - i64, `1..=i64::MAX`. Unparseable or out of range: `ERR bad capacity`. Zero specifically: `ERR (capacity should be larger than 0)`.
- **Trailing arg** (`argc > 4`):
  - argc 5 + `NONSCALING` -> `expansion = 0`.
  - argc 6 + `EXPANSION <u32>` -> range `1..=u32::MAX`. Invalid: `ERR bad expansion`.
  - Anything else: `ERR ERROR`.

Key check: existing bloom -> `ERR item exists`. Non-bloom type -> `WrongType`. BF.RESERVE never overwrites.

Creation: current config provides `tightening_ratio` and seed mode. `new_reserved` with size validation gated by `!must_obey_client(ctx)`. Replicates with `reserve_operation: true`, items empty. Default expansion when argc==4 is `BLOOM_EXPANSION` (2).

## BF.INSERT

`BF.INSERT key [ERROR fp] [CAPACITY cap] [EXPANSION exp] [NOCREATE] [NONSCALING] [TIGHTENING ratio] [SEED bytes] [VALIDATESCALETO cap] ITEMS item [item ...]`

Minimum arity 2 - can create an empty bloom.

Defaults come from current module config; explicit args override.

### Keyword table (case-insensitive, parsed in a `while idx < argc` loop)

| Keyword | Value | Parsing / errors |
|---------|-------|------------------|
| `ERROR` | f64 `(0, 1)` | `ERR (0 < error rate range < 1)` |
| `TIGHTENING` | f64 `(0, 1)` | replication-internal. `ERR bad tightening ratio` / `ERR (0 < tightening ratio range < 1)` |
| `CAPACITY` | i64 `1..=i64::MAX` | zero -> `ERR (capacity should be larger than 0)` |
| `SEED` | exactly 32 bytes | replication-internal. `try_into()` failure -> `ERR invalid seed` |
| `NOCREATE` | none | sets flag |
| `NONSCALING` | none | `expansion = 0` |
| `EXPANSION` | u32 `1..=u32::MAX` | |
| `VALIDATESCALETO` | i64 `1..=i64::MAX` | zero -> `ERR (capacity should be larger than 0)` |
| `ITEMS` | (sentinel) | advances idx, sets `items_provided = true`, breaks loop |

Unknown keyword: `ERR unknown argument received`. Value-expecting keywords check `idx >= (argc - 1)` -> `WrongArity`. `ITEMS` with no items: `WrongArity`.

### Replication-internal args

Source comment on `TIGHTENING`:

> This argument is only supported on replicated commands since primary nodes replicate bloom objects deterministically using every global bloom config/property.

Same applies to `SEED`. Both arrive only in the synthetic `BF.INSERT` the primary sends to replicas.

`SEED` parsing: raw bytes -> `[u8; 32]` via `try_into()`. `is_seed_random` is derived by comparing against `FIXED_SEED` - different -> random, equal -> fixed.

### VALIDATESCALETO check

Run post-parse, before creation. Not replicated.

1. `expansion == 0` (NONSCALING also present) -> `ERR cannot use NONSCALING and VALIDATESCALETO options together`.
2. Call `BloomObject::calculate_max_scaled_capacity(capacity, fp_rate, scale_to, tightening_ratio, expansion)`.
3. Failures:
   - FP degrades to zero: `ERR provided VALIDATESCALETO causes false positive to degrade to 0`.
   - Memory limit: `ERR provided VALIDATESCALETO causes bloom object to exceed memory limit`.

### NOCREATE

Key missing + `nocreate` -> `ERR not found`. Key existing + `nocreate` -> no effect, items added normally.

### Existing vs new key

- **Existing** (`Some`): items added to existing bloom. Option args (CAPACITY, ERROR, etc.) **ignored**. Replication uses `reserve_operation: false`; verbatim only if at least one item was new. `ReplicateArgs` pulls from the **object's** properties, not the current command's overrides.
- **New** (`None`, no NOCREATE): create with parsed params (or defaults). Size validation gated. `new_reserved` + `handle_bloom_add` with `multi: true` for items. `set_value`, replicate with `reserve_operation: true`.

Response is always `ValkeyValue::Array` of integer add-results. Empty ITEMS on new key -> empty array.

## BF.LOAD - internal, AOF-only

`BF.LOAD key data`. Arity exactly 3. Flags: `write deny-oom` (note: no `fast`). ACL: `write bloom`.

Key existence -> `BUSYKEY Target key name already exists.` (`utils::KEY_EXISTS`). Non-bloom type -> `WrongType`.

Data is the raw bytes from `BloomObject::encode_object`:

1. `decode_object(&data, validate_size_limit)` - byte 0 is version (must be 1), bincode-deserializes `bytes[1..]` into `(u32, f64, f64, bool, Vec<Box<BloomFilter>>)`.
2. Validates expansion, fp_rate, tightening_ratio, filter count, total memory.
3. Failure: `ERR bloom object decoding failed` or `ERR bloom object decoding failed. Unsupported version`.

Size validation gated by `!must_obey_client`. After decode, replicates with `reserve_operation: true` - **replica receives a synthetic BF.INSERT** with full properties + items (including the encoded data in items list). Replica ends up building the bloom via BF.INSERT, not replaying BF.LOAD.

## Error summary

| Command | Error | When |
|---------|-------|------|
| BF.RESERVE | `ERR item exists` | key holds bloom |
| BF.RESERVE | `ERR bad error rate` / `ERR (0 < error rate range < 1)` | fp_rate parse / range |
| BF.RESERVE | `ERR bad capacity` / `ERR (capacity should be larger than 0)` | cap parse / zero |
| BF.RESERVE | `ERR bad expansion` | expansion parse / range |
| BF.RESERVE | `ERR ERROR` | unknown trailing arg |
| BF.INSERT | `ERR not found` | NOCREATE + key missing |
| BF.INSERT | `ERR unknown argument received` | unknown keyword |
| BF.INSERT | `ERR invalid seed` | SEED not 32 bytes |
| BF.INSERT | `ERR bad tightening ratio` / `ERR (0 < tightening ratio range < 1)` | TIGHTENING parse / range |
| BF.INSERT | `ERR cannot use NONSCALING and VALIDATESCALETO options together` | both set |
| BF.INSERT | `ERR provided VALIDATESCALETO causes false positive to degrade to 0` | scale sim FP zero |
| BF.INSERT | `ERR provided VALIDATESCALETO causes bloom object to exceed memory limit` | scale sim memory |
| BF.LOAD | `BUSYKEY Target key name already exists.` | key exists |
| BF.LOAD | `ERR bloom object decoding failed` / `... Unsupported version` | bincode fail / version != 1 |
