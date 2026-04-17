# Code structure

Use when navigating the codebase, adding a new command, or understanding module registration and error handling.

Source: `src/lib.rs`, `src/bloom/*`, `src/wrapper/*`, `src/commands/*.json`.

## Directory layout

```
src/
  lib.rs                  # valkey_module! macro, command wrappers, initialize/deinitialize
  configs.rs              # FIXED_SEED, range consts, lazy_static config statics, on_string_config_set
  metrics.rs              # AtomicU64/usize counters for INFO bf
  bloom/
    mod.rs                # re-exports command_handler, data_type, utils
    command_handler.rs    # all BF.* command impls
    data_type.rs          # BLOOM_TYPE ("bloomfltr"), RDB load, version constants
    utils.rs              # BloomObject, BloomFilter, BloomError, error strings, unit tests
  wrapper/
    mod.rs                # must_obey_client - 8.0 vs 8.1+ feature-gated
    bloom_callback.rs     # unsafe extern "C" callbacks: RDB save/load, AOF rewrite, free, copy, defrag, digest
  commands/
    bf.{add,card,exists,info,insert,load,madd,mexists,reserve}.json  # COMMAND DOCS metadata (9 files)
```

## Module registration

```rust
valkey_module! {
    name:     MODULE_NAME,        // "bf"
    version:  MODULE_VERSION,     // 999999 on dev, rewritten at release
    allocator: (ValkeyAlloc, ValkeyAlloc),
    data_types: [BLOOM_TYPE],     // "bloomfltr"
    init:     initialize,
    deinit:   deinitialize,
    acl_categories: ["bloom"],
    commands: [ /* 9 */ ],
    configurations: [ /* i64 / string / bool sections + module_args_as_configuration: true */ ],
}
```

`MODULE_RELEASE_STAGE` is also registered: `"dev"` on unstable, flipped through `"rc1"..`"rcN"`, finally `"ga"` at release.

### initialize

```rust
fn initialize(ctx: &Context, _args: &[ValkeyString]) -> Status {
    ctx.set_module_options(ModuleOptions::HANDLE_IO_ERRORS);
    let ver = ctx.get_server_version().expect("Unable to get server version!");
    if !valid_server_version(ver) { Status::Err } else { Status::Ok }
}
```

`BLOOM_MIN_SUPPORTED_VERSION = &[8, 0, 0]`. `deinitialize` is a no-op.

## Command registration pattern

One entry per command:

```rust
["BF.ADD", bloom_add_command, "write fast deny-oom", 1, 1, 1, "fast write bloom"],
```

Fields: name, handler, flags, first-key, last-key, step, ACL categories.

Flags used: `write`, `readonly`, `fast`, `deny-oom`. **BF.LOAD is the only command without `fast`** - `"write deny-oom"` - since it deserializes an entire bloom.

Wrapper functions in `lib.rs` are thin dispatchers to `command_handler::`, using a `multi: bool` parameter for ADD/MADD and EXISTS/MEXISTS (one shared handler each):

```rust
fn bloom_add_command  (ctx, args) { command_handler::bloom_filter_add_value(ctx, &args, false) }
fn bloom_madd_command (ctx, args) { command_handler::bloom_filter_add_value(ctx, &args, true)  }
```

`#[info_command_handler]` macro on `info_handler` registers the INFO section handler delegating to `metrics::bloom_info_handler`.

## Command JSON metadata (`src/commands/bf.*.json`)

One file per command, fed to `COMMAND DOCS`. Shape:

```json
{
  "BF.ADD": {
    "summary":       "...",
    "complexity":    "O(N), N = hash functions",
    "group":         "bloom",
    "module_since":  "1.0.0",
    "arity":         3,
    "acl_categories": ["FAST", "WRITE", "BLOOM"],
    "arguments":     [ { "name": "key", "type": "key", "key_spec_index": 0 }, ... ]
  }
}
```

| Field | Use |
|-------|-----|
| `arity` | positive = fixed, negative = minimum (e.g. `-2` for variadic) |
| `arguments[].optional: true` | keyword arg |
| `arguments[].multiple: true` | repeatable |

## ACL category

Custom category `"bloom"` registered via `acl_categories: ["bloom"]`. Every command includes it (e.g. `"fast write bloom"`). Grant via `ACL SETUSER <user> +@bloom` / `-@bloom`.

## Error types

`BloomError` in `src/bloom/utils.rs`:

```rust
pub enum BloomError {
    NonScalingFilterFull, MaxNumScalingFilters, ExceedsMaxBloomSize,
    EncodeBloomFilterFailed, DecodeBloomFilterFailed, DecodeUnsupportedVersion,
    ErrorRateRange, BadExpansion, FalsePositiveReachesZero, BadCapacity,
    ValidateScaleToExceedsMaxSize, ValidateScaleToFalsePositiveInvalid,
}
```

`as_str()` maps each to a `&'static str` (one of the `ERR ...` constants defined at the top of `utils.rs`: `NOT_FOUND`, `ITEM_EXISTS`, `INVALID_INFO_VALUE`, `INVALID_SEED`, `BAD_ERROR_RATE`, `BAD_TIGHTENING_RATIO`, `TIGHTENING_RATIO_RANGE`, `CAPACITY_LARGER_THAN_0`, `UNKNOWN_ARGUMENT`, `KEY_EXISTS`, `NON_SCALING_AND_VALIDATE_SCALE_TO_IS_INVALID`).

Translation to command returns:

```rust
Err(ValkeyError::Str(utils::NOT_FOUND))            // single-value return
result.push(ValkeyValue::StaticError(err.as_str())) // multi-value (MADD, INSERT)
Err(ValkeyError::WrongArity)
Err(ValkeyError::WrongType)
```

Handler pattern: parse with early returns on validation failure -> `open_key_writable` / `open_key` -> `get_value::<BloomObject>(&BLOOM_TYPE)` (handles `WrongType`) -> operate -> replicate if mutative.

## Replication (summary - full in `commands-replication.md`)

- Creation always replicates as a **synthetic BF.INSERT** with full properties (capacity, fp_rate, tightening_ratio, seed, expansion, items). SEED and TIGHTENING are replication-internal args.
- Item addition on existing bloom: `ctx.replicate_verbatim()`.
- Duplicate add (no new item): no replication.
- `must_obey_client(ctx)` true (replica / AOF replay) -> size limit checks skipped.
- Keyspace events: `bloom.reserve` on creation, `bloom.add` on any new-item insert. Both can fire in one call.

## Adding a new command (checklist)

1. `src/commands/bf.newcmd.json` - metadata with `summary`, `arity`, `acl_categories`, etc.
2. Implement `pub fn bloom_filter_newcmd(ctx: &Context, input_args: &[ValkeyString]) -> ValkeyResult` in `src/bloom/command_handler.rs`. Follow the parse -> open -> type-check -> operate -> replicate pattern.
3. Thin wrapper in `src/lib.rs`.
4. Register in `valkey_module!` `commands` array with the right flags and ACL categories.
5. Unit tests in `utils.rs`; integration tests in `tests/test_bloom_*.py`.
6. Add the command name to the `bf_cmds` list in `test_bloom_basic.py::test_basic` (module-load sanity check).
