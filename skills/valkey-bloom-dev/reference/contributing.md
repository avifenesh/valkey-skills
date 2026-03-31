# Contributing to valkey-bloom

Use when adding new commands, modifying bloom filter behavior, understanding code organization, replication patterns, or Rust module patterns used in the project.

## Code Structure

```
src/
  lib.rs                    # Module entry point, command registration, valkey_module! macro
  configs.rs                # Module configs (lazy_static atomics), validation
  metrics.rs                # Global atomic counters, INFO handler
  bloom/
    mod.rs                  # Re-exports: command_handler, data_type, utils
    command_handler.rs      # Command implementations (BF.ADD, BF.EXISTS, etc.)
    data_type.rs            # ValkeyType definition, RDB load, digest
    utils.rs                # BloomObject, BloomFilter structs, core logic, unit tests
  wrapper/
    mod.rs                  # must_obey_client helper (8.0 vs 8.1 compat)
    bloom_callback.rs       # Unsafe extern "C" callbacks: RDB save/load, AOF, defrag, copy, free
tests/
  conftest.py               # Pytest fixtures (seed parameterization)
  valkey_bloom_test_case.py  # Base test class extending ValkeyTestCase
  test_bloom_*.py           # Integration test suites
```

## Adding a New Command

1. **Add handler function** in `src/bloom/command_handler.rs`:

```rust
pub fn bloom_filter_mycommand(ctx: &Context, input_args: &[ValkeyString]) -> ValkeyResult {
    let argc = input_args.len();
    if argc != 3 {
        return Err(ValkeyError::WrongArity);
    }
    let filter_name = &input_args[1];
    let filter_key = ctx.open_key(filter_name);  // open_key_writable for mutations
    let value = match filter_key.get_value::<BloomObject>(&BLOOM_TYPE) {
        Ok(v) => v,
        Err(_) => return Err(ValkeyError::WrongType),
    };
    // ... implement logic
    Ok(ValkeyValue::Integer(result))
}
```

2. **Add wrapper function** in `src/lib.rs`:

```rust
fn bloom_mycommand_command(ctx: &Context, args: Vec<ValkeyString>) -> ValkeyResult {
    command_handler::bloom_filter_mycommand(ctx, &args)
}
```

3. **Register in `valkey_module!`** macro in `src/lib.rs`:

```rust
commands: [
    // ... existing commands
    ["BF.MYCOMMAND", bloom_mycommand_command, "readonly fast", 1, 1, 1, "fast read bloom"],
]
```

Command flag strings: `"write fast deny-oom"` for mutative, `"readonly fast"` for reads. The `deny-oom` flag rejects commands when OOM. The `1, 1, 1` arguments are first-key, last-key, key-step.

4. **Add ACL category**: All commands use the `"bloom"` ACL category (registered in `acl_categories`).

5. **Add tests**: Unit test in `utils.rs` `mod tests`, integration test in `tests/test_bloom_command.py` or a new file.

## Write Command Pattern

Mutative commands follow a consistent pattern:

```rust
pub fn bloom_filter_mutate(ctx: &Context, input_args: &[ValkeyString]) -> ValkeyResult {
    // 1. Parse args
    let filter_name = &input_args[1];
    // 2. Open key writable
    let filter_key = ctx.open_key_writable(filter_name);
    let value = filter_key.get_value::<BloomObject>(&BLOOM_TYPE)?;
    // 3. Skip size validation on replicated commands
    let validate_size_limit = !must_obey_client(ctx);
    // 4. Create or modify
    match value {
        Some(bloom) => { /* modify existing */ }
        None => {
            let bloom = BloomObject::new_reserved(...)?;
            filter_key.set_value(&BLOOM_TYPE, bloom)?;
        }
    }
    // 5. Replicate and notify
    replicate_and_notify_events(ctx, filter_name, add_op, reserve_op, replicate_args);
    Ok(result)
}
```

## Replication Strategy

Replication is deterministic. The module does not replicate commands verbatim for object creation. Instead:

- **Reserve (object creation)**: Replicated as `BF.INSERT <key> CAPACITY <cap> ERROR <fp> TIGHTENING <ratio> SEED <32bytes> [EXPANSION <exp> | NONSCALING] ITEMS <items...>`. This ensures replicas create identical bloom objects with the same seed and properties.
- **Add-only (no creation)**: Replicated verbatim via `ctx.replicate_verbatim()`.

The `ReplicateArgs` struct in `command_handler.rs` carries all bloom object properties needed for deterministic replication.

## Keyspace Notifications

Two events defined in `utils.rs`:
- `bloom.add` - fired on item addition
- `bloom.reserve` - fired on object creation

Published via `ctx.notify_keyspace_event(NotifyEvent::GENERIC, event, key_name)`.

## Adding a Module Config

1. Add constants in `src/configs.rs`:

```rust
pub const MY_CONFIG_DEFAULT: i64 = 42;
pub const MY_CONFIG_MIN: i64 = 0;
pub const MY_CONFIG_MAX: i64 = 1000;
lazy_static! {
    pub static ref MY_CONFIG: AtomicI64 = AtomicI64::new(MY_CONFIG_DEFAULT);
}
```

2. Register in the `valkey_module!` macro's `configurations` block:

```rust
configurations: [
    i64: [
        ["bloom-my-config", &*configs::MY_CONFIG, configs::MY_CONFIG_DEFAULT, configs::MY_CONFIG_MIN, configs::MY_CONFIG_MAX, ConfigurationFlags::DEFAULT, None],
    ],
]
```

For float-like configs, use string type with a custom set handler (see `on_string_config_set` for `bloom-fp-rate` pattern).

## Valkey 8.0 vs 8.1 Compatibility

The `valkey_8_0` feature flag controls one key behavioral difference in `src/wrapper/mod.rs`:

- **8.1+**: Uses `ValkeyModule_MustObeyClient` API (more performant)
- **8.0**: Falls back to checking `ContextFlags::REPLICATED` via `get_flags()`

Both determine whether to skip size validation on replicated commands.

## Data Type Callbacks

Defined in `src/bloom/data_type.rs` (type registration) and `src/wrapper/bloom_callback.rs` (unsafe implementations):

| Callback | Purpose |
|----------|---------|
| `rdb_save` / `rdb_load` | Persistence - serialize/deserialize to RDB |
| `aof_rewrite` | Emit `BF.LOAD` with bincode-encoded object |
| `mem_usage` | Report memory for `MEMORY USAGE` command |
| `free` | Drop the BloomObject (Box drop) |
| `copy` | Deep copy for `COPY` command |
| `digest` | Debug digest for `DEBUG DIGEST-VALUE` |
| `free_effort` | Returns filter count (async free threshold) |
| `defrag` | Cursor-based incremental defragmentation |
| `aux_load` | Load auxiliary data (no-op, logs notice) |

## Error Constants

All error strings are defined in `src/bloom/utils.rs` as `pub const` strings and wrapped in the `BloomError` enum. Keep errors consistent with the existing style:

```rust
pub const MY_ERROR: &str = "ERR description of what went wrong";
```

Add new variants to `BloomError` enum and implement `as_str()` mapping.

## Dependencies

| Crate | Version | Purpose |
|-------|---------|---------|
| `valkey-module` | 0.1.5 | Valkey module SDK (types, context, raw API) |
| `valkey-module-macros` | 0 | `#[info_command_handler]` proc macro |
| `bloomfilter` | 3.0.1 | Core bloom filter with serde support |
| `serde` + `bincode` | 1.0 / 1.3 | Serialization for BF.LOAD / AOF rewrite |
| `lazy_static` | 1.4 | Global config statics |
| `libc` | 0.2 | C FFI types for callbacks |
| `linkme` | 0 | Distributed slice (module macro internals) |
| `rand` (dev) | 0.8 | Random test data |
| `rstest` (dev) | 0.23 | Parameterized unit tests |
