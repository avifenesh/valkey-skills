# Code Structure

Use when navigating the codebase, adding new commands, understanding module registration, or working with error handling patterns.

Source: `src/lib.rs`, `src/bloom/mod.rs`, `src/bloom/command_handler.rs`, `src/bloom/utils.rs`, `src/commands/*.json`

## Contents

- Directory Layout (line 21)
- Module Registration (line 48)
- Command Registration Pattern (line 85)
- Command Metadata JSON (line 122)
- ACL Category (line 157)
- Module Configurations (line 167)
- Error Types and Handling (line 188)
- Replication Pattern (line 229)
- Adding a New Command (line 243)

---

## Directory Layout

```
src/
  lib.rs                  # Entry point: valkey_module! macro, command wrappers, initialize/deinitialize
  configs.rs              # Configuration constants, defaults, lazy_static config statics, config set handler
  metrics.rs              # Atomic counters for INFO metrics (objects, memory, filters, items, capacity, defrag)
  bloom/
    mod.rs                # Re-exports: command_handler, data_type, utils
    command_handler.rs    # Command implementations (BF.ADD, BF.EXISTS, BF.RESERVE, BF.INSERT, etc.)
    data_type.rs          # ValkeyType registration ("bloomfltr"), RDB load/save trait, encoding version
    utils.rs              # BloomObject/BloomFilter structs, error types, error strings, unit tests
  wrapper/
    mod.rs                # must_obey_client() - version-aware check for replicated commands
    bloom_callback.rs     # Unsafe extern "C" callbacks: RDB save/load, AOF rewrite, free, copy, defrag, digest
  commands/
    bf.add.json           # Command metadata for BF.ADD
    bf.card.json          # Command metadata for BF.CARD
    bf.exists.json        # Command metadata for BF.EXISTS
    bf.info.json          # Command metadata for BF.INFO
    bf.insert.json        # Command metadata for BF.INSERT
    bf.load.json          # Command metadata for BF.LOAD (internal, used for AOF rewrite)
    bf.madd.json          # Command metadata for BF.MADD
    bf.mexists.json       # Command metadata for BF.MEXISTS
    bf.reserve.json       # Command metadata for BF.RESERVE
```

## Module Registration

The `valkey_module!` macro in `src/lib.rs` registers the module with Valkey:

```rust
valkey_module! {
    name: MODULE_NAME,              // "bf"
    version: MODULE_VERSION,        // 999999 (dev), set during release
    allocator: (ValkeyAlloc, ValkeyAlloc),
    data_types: [BLOOM_TYPE],       // "bloomfltr" from data_type.rs
    init: initialize,
    deinit: deinitialize,
    acl_categories: ["bloom"]
    commands: [ /* 9 commands */ ],
    configurations: [ /* i64, string, bool, enum sections */ ],
}
```

Also registered: `MODULE_RELEASE_STAGE` (a constant set to `"dev"` on unstable, changed to `"rc1"`...`"rcN"` and finally `"ga"` during release), and `module_args_as_configuration: true` which allows passing configs as module load arguments.

The `initialize` function runs on module load. It sets `HANDLE_IO_ERRORS` for graceful RDB error handling and validates the server version against `configs::BLOOM_MIN_SUPPORTED_VERSION` (8.0.0):

```rust
fn initialize(ctx: &Context, _args: &[ValkeyString]) -> Status {
    ctx.set_module_options(ModuleOptions::HANDLE_IO_ERRORS);
    let ver = ctx.get_server_version().expect("Unable to get server version!");
    if !valid_server_version(ver) {
        // Log warning and return Err - minimum is 8.0.0
        Status::Err
    } else {
        Status::Ok
    }
}
```

The `deinitialize` function is a no-op returning `Status::Ok`.

## Command Registration Pattern

Each command is registered in the `commands` array of `valkey_module!` with this format:

```rust
["BF.ADD", bloom_add_command, "write fast deny-oom", 1, 1, 1, "fast write bloom"],
```

The fields are: command name, handler function, flags, first key, last key, step, ACL categories.

Command flags used in this module:

| Flag | Meaning |
|------|---------|
| `write` | Command modifies data |
| `readonly` | Command only reads data |
| `fast` | O(1) or O(log N) complexity |
| `deny-oom` | Reject when server is over maxmemory |

BF.LOAD uses `"write deny-oom"` without `fast` - the only command without the fast flag since it deserializes an entire bloom object.

Each wrapper function in `lib.rs` is a thin dispatcher to `command_handler.rs`:

```rust
fn bloom_add_command(ctx: &Context, args: Vec<ValkeyString>) -> ValkeyResult {
    command_handler::bloom_filter_add_value(ctx, &args, false)
}

fn bloom_madd_command(ctx: &Context, args: Vec<ValkeyString>) -> ValkeyResult {
    command_handler::bloom_filter_add_value(ctx, &args, true)
}
```

The `multi` boolean distinguishes single-item from multi-item variants. The same pattern applies to EXISTS/MEXISTS.

An `#[info_command_handler]` macro on `info_handler` registers the custom INFO section handler that delegates to `metrics::bloom_info_handler`.

## Command Metadata JSON

Each command has a JSON file in `src/commands/` that describes its schema for `COMMAND DOCS`. Example from `bf.add.json`:

```json
{
    "BF.ADD": {
        "summary": "Add a single item to a bloom filter...",
        "complexity": "O(N), where N is the number of hash functions...",
        "group": "bloom",
        "module_since": "1.0.0",
        "arity": 3,
        "acl_categories": ["FAST", "WRITE", "BLOOM"],
        "arguments": [
            { "name": "key", "type": "key", "key_spec_index": 0 },
            { "name": "value", "type": "string" }
        ]
    }
}
```

**Key fields**:

| Field | Description |
|-------|-------------|
| `summary` | One-line description shown in `COMMAND DOCS` |
| `complexity` | Big-O complexity string |
| `group` | Command group - always `"bloom"` |
| `module_since` | Module version that introduced the command |
| `arity` | Fixed arity (positive) or minimum arity (negative, e.g., `-2` for variadic) |
| `acl_categories` | ACL categories for access control |
| `arguments` | Array of argument descriptors with `name`, `type`, and optional `token`, `optional`, `multiple` |

For variadic commands like BF.INSERT, arguments with `"optional": true` denote keyword arguments, and `"multiple": true` indicates repeatable arguments.

## ACL Category

The module registers a custom ACL category `"bloom"` in the `valkey_module!` macro:

```rust
acl_categories: ["bloom"]
```

All commands include `"bloom"` in their ACL categories string (e.g., `"fast write bloom"`). This allows operators to control access with `ACL SETUSER user +@bloom` or `-@bloom`. See `reference/commands/command-handlers.md` for the full command-to-flag mapping.

## Module Configurations

Configurations are registered in the `configurations` block of `valkey_module!`. Four types:

**Integer configs** (`i64`):
- `bloom-capacity` - default initial capacity (default: 100, range: 1 to i64::MAX)
- `bloom-expansion` - default expansion factor (default: 2, range: 0 to u32::MAX). 0 means non-scaling
- `bloom-memory-usage-limit` - max bytes per bloom object (default: 128MB, range: 0 to i64::MAX)

**String configs** (stored as `ValkeyGILGuard<ValkeyString>`, parsed as `f64`):
- `bloom-fp-rate` - default false positive rate (default: "0.01", range: exclusive (0, 1))
- `bloom-tightening-ratio` - FP decay per scale-out (default: "0.5", range: exclusive (0, 1))

String configs use a custom `on_string_config_set` handler in `configs.rs` that validates the range and updates a paired `Mutex<f64>` (`BLOOM_FP_RATE_F64`, `BLOOM_TIGHTENING_F64`) for fast access in command handlers.

**Boolean configs**:
- `bloom-use-random-seed` - use random vs fixed hash seed (default: true)
- `bloom-defrag-enabled` - enable active defragmentation (default: true)

All configs are runtime-modifiable via `CONFIG SET bf.<name> <value>` and readable via `CONFIG GET bf.<name>`. See `reference/commands/module-configs.md` for full config details.

## Error Types and Handling

Errors are defined in `src/bloom/utils.rs` as the `BloomError` enum:

```rust
pub enum BloomError {
    NonScalingFilterFull,        // "ERR non scaling filter is full"
    MaxNumScalingFilters,        // "ERR bloom object reached max number of filters"
    ExceedsMaxBloomSize,         // "ERR operation exceeds bloom object memory limit"
    EncodeBloomFilterFailed,     // "Failed to encode bloom object."
    DecodeBloomFilterFailed,     // "ERR bloom object decoding failed"
    DecodeUnsupportedVersion,    // "ERR bloom object decoding failed. Unsupported version"
    ErrorRateRange,              // "ERR (0 < error rate range < 1)"
    BadExpansion,                // "ERR bad expansion"
    FalsePositiveReachesZero,    // "ERR false positive degrades to 0 on scale out"
    BadCapacity,                 // "ERR bad capacity"
    ValidateScaleToExceedsMaxSize,
    ValidateScaleToFalsePositiveInvalid,
}
```

Additional error string constants are defined at the top of `utils.rs` for argument validation: `NOT_FOUND`, `ITEM_EXISTS`, `INVALID_INFO_VALUE`, `INVALID_SEED`, `BAD_ERROR_RATE`, `BAD_TIGHTENING_RATIO`, `TIGHTENING_RATIO_RANGE`, `CAPACITY_LARGER_THAN_0`, `UNKNOWN_ARGUMENT`, `KEY_EXISTS`, and `NON_SCALING_AND_VALIDATE_SCALE_TO_IS_INVALID`.

Each variant maps to a static `&str` via `as_str()`. In command handlers, errors convert to `ValkeyError`:

```rust
// For single-value returns:
Err(ValkeyError::Str(utils::NOT_FOUND))

// For multi-value returns (MADD, INSERT):
result.push(ValkeyValue::StaticError(err.as_str()));

// For arity errors:
Err(ValkeyError::WrongArity)

// For type mismatches:
Err(ValkeyError::WrongType)
```

The pattern: parse arguments with early returns on validation failure, open the key writable, check for type errors via `get_value::<BloomObject>(&BLOOM_TYPE)`, and proceed with the operation.

## Replication Pattern

Mutative commands use deterministic replication through `replicate_and_notify_events()` in `command_handler.rs`. See `reference/commands/replication.md` for full details.

**Bloom creation** is always replicated as `BF.INSERT` with exact properties from the primary (capacity, fp_rate, tightening_ratio, seed, expansion, items). This ensures the replica creates an identical bloom object regardless of its local config.

**Item addition** to an existing bloom uses `ctx.replicate_verbatim()` - the original command is forwarded as-is.

**No replication** occurs when an item already exists (add returns 0) since no state changed.

The `must_obey_client` wrapper (in `src/wrapper/mod.rs`) detects replicated commands. On Valkey 8.1+, it uses `ValkeyModule_MustObeyClient`. On Valkey 8.0 (with `valkey_8_0` feature), it falls back to checking `ContextFlags::REPLICATED`. When a command is replicated, size limit validation is skipped to avoid rejecting data the primary already accepted.

Keyspace notifications are published for both creation (`bloom.reserve`) and item addition (`bloom.add`) events.

## Adding a New Command

Step-by-step process for adding a hypothetical `BF.NEWCMD`:

1. **Create command metadata** - add `src/commands/bf.newcmd.json`:
   ```json
   {
       "BF.NEWCMD": {
           "summary": "Description of the new command",
           "complexity": "O(1)",
           "group": "bloom",
           "module_since": "1.1.0",
           "arity": 3,
           "acl_categories": ["FAST", "READ", "BLOOM"],
           "arguments": [...]
       }
   }
   ```

2. **Implement the handler** - add a `pub fn bloom_filter_newcmd(ctx: &Context, input_args: &[ValkeyString]) -> ValkeyResult` function in `src/bloom/command_handler.rs`. Follow the existing pattern: validate arity, parse arguments, open key, get typed value, perform operation, handle replication if mutative.

3. **Add the wrapper** - in `src/lib.rs`, add a thin wrapper function:
   ```rust
   fn bloom_newcmd_command(ctx: &Context, args: Vec<ValkeyString>) -> ValkeyResult {
       command_handler::bloom_filter_newcmd(ctx, &args)
   }
   ```

4. **Register the command** - add to the `commands` array in `valkey_module!`:
   ```rust
   ["BF.NEWCMD", bloom_newcmd_command, "readonly fast", 1, 1, 1, "fast read bloom"],
   ```

5. **Write tests** - add unit tests in `src/bloom/utils.rs` if the command involves new BloomObject logic. Add integration tests in a new or existing `tests/test_bloom_*.py` file.

6. **Update test_basic** - add the new command name to the `bf_cmds` list in `test_bloom_basic.py::test_basic` so module loading validation includes it.