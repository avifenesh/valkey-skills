# Module configs

Use when reasoning about bloom-* config defaults, ranges, the string-as-f64 pattern, or `module_args_as_configuration`.

Source: `src/configs.rs`, `src/lib.rs` (`valkey_module!` configurations block).

## Config table

| Config | Type | Default | Range | Purpose |
|--------|------|---------|-------|---------|
| `bloom-capacity` | i64 | 100 | `1..=i64::MAX` | Default initial capacity (auto-created blooms) |
| `bloom-expansion` | i64 | 2 | `0..=u32::MAX` | Scale factor; 0 = non-scaling |
| `bloom-fp-rate` | string | `"0.01"` | exclusive `(0, 1)` | Default FP rate |
| `bloom-tightening-ratio` | string | `"0.5"` | exclusive `(0, 1)` | FP decay per scale-out |
| `bloom-memory-usage-limit` | i64 | `128 * 1024 * 1024` | `0..=i64::MAX` | Max bytes per bloom object |
| `bloom-use-random-seed` | bool | true | - | Random vs `FIXED_SEED` |
| `bloom-defrag-enabled` | bool | true | - | Enable incremental defrag |

All use `ConfigurationFlags::DEFAULT`. Only the string configs have a custom validator (`on_string_config_set`). Runtime-settable via `CONFIG SET bf.<name> <value>`.

## Integer / bool configs - storage

`AtomicI64` / `AtomicBool` with `Ordering::Relaxed` reads throughout:

```rust
pub static ref BLOOM_CAPACITY:        AtomicI64  = AtomicI64::new(BLOOM_CAPACITY_DEFAULT);
pub static ref BLOOM_EXPANSION:       AtomicI64  = AtomicI64::new(BLOOM_EXPANSION_DEFAULT);
pub static ref BLOOM_MEMORY_LIMIT_PER_OBJECT: AtomicI64 = ...;
pub static ref BLOOM_USE_RANDOM_SEED: AtomicBool = AtomicBool::default();  // overridden at load to true
pub static ref BLOOM_DEFRAG:          AtomicBool = AtomicBool::new(BLOOM_DEFRAG_DEFAULT);
```

Note: `bloom-expansion` register-range allows 0 (non-scaling), while command-level `EXPANSION` arg floor is `BLOOM_EXPANSION_MIN` (1). Zero is reachable only via config or `NONSCALING` keyword.

`bloom-memory-usage-limit = 0` blocks all bloom creation (any object has size > 0).

## String-as-f64 configs

Valkey module config system has no native f64 type. Both `bloom-fp-rate` and `bloom-tightening-ratio` use:

- **External storage**: `ValkeyGILGuard<ValkeyString>` - what CONFIG SET/GET sees.
- **Internal cache**: `Mutex<f64>` - what command handlers read to avoid repeated string parsing.

```rust
pub static ref BLOOM_FP_RATE:       ValkeyGILGuard<ValkeyString> = ValkeyGILGuard::new(...);
pub static ref BLOOM_FP_RATE_F64:   Mutex<f64>                   = Mutex::new(0.01);
pub static ref BLOOM_TIGHTENING_RATIO: ValkeyGILGuard<ValkeyString> = ...;
pub static ref BLOOM_TIGHTENING_F64:   Mutex<f64>                   = Mutex::new(0.5);
```

`on_string_config_set(ctx, name, val)`:

1. `to_string_lossy()`, `parse::<f64>()`. Parse error -> `"Invalid floating-point value"`.
2. Range check:
   - `bloom-fp-rate` out of range -> `ERR (0 < error rate range < 1)`.
   - `bloom-tightening-ratio` out of range -> `ERR (0 < tightening ratio range < 1)`.
3. Update the corresponding `Mutex<f64>`.

Registered via `Some(Box::new(configs::on_string_config_set))` as the last parameter of each string config entry in `valkey_module!`.

## `module_args_as_configuration`

```rust
configurations: [ ..., module_args_as_configuration: true ]
```

Makes module load arguments flow through the config system:

```
valkey-server --loadmodule ./libvalkey_bloom.so bloom-capacity 1000 bloom-fp-rate 0.001
```

No custom `_args` parsing needed in `initialize` - `_args: &[ValkeyString]` is unused.

## Other module constants (in `src/configs.rs`)

- `FIXED_SEED: [u8; 32]` - used when `bloom-use-random-seed=false`, also the `is_seed_random` comparison baseline for BF.INSERT SEED parsing.
- `BLOOM_NUM_FILTERS_PER_OBJECT_LIMIT_MAX: i32 = i32::MAX` - hard cap, checked in `add_item` and `decode_object`.
- `BLOOM_MIN_SUPPORTED_VERSION: &[i64; 3] = &[8, 0, 0]` - checked in `initialize`; below returns `Status::Err`.
- Range constants: `BLOOM_EXPANSION_MAX` (u32::MAX), `BLOOM_FP_RATE_MIN`/`MAX` (0.0 / 1.0), `BLOOM_TIGHTENING_RATIO_MIN`/`MAX` (0.0 / 1.0).
