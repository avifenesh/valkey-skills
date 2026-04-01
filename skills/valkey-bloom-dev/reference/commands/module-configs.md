# Module Configuration Options

Use when understanding bloom module config defaults, ranges, types, the custom string-to-f64 config handler, or the module_args_as_configuration pattern.

Source: `src/configs.rs`, `src/lib.rs` (valkey_module! configurations block)

## Contents

- Configuration Table (line 22)
- Integer Configs (line 36)
- String Configs (line 46)
- Boolean Configs (line 54)
- Custom String Config Handler (line 60)
- Config Storage Pattern (line 92)
- module_args_as_configuration (line 115)
- Fixed Seed Constant (line 134)
- Other Constants (line 145)

---

## Configuration Table

| Config | Type | Default | Min | Max | Purpose |
|--------|------|---------|-----|-----|---------|
| `bloom-capacity` | i64 | 100 | 1 | i64::MAX | Default items per sub-filter |
| `bloom-expansion` | i64 | 2 | 0 | u32::MAX | Scale factor (0 = non-scaling) |
| `bloom-fp-rate` | string | "0.01" | (0 | 1) | Default false positive rate |
| `bloom-tightening-ratio` | string | "0.5" | (0 | 1) | FP decay per scale-out |
| `bloom-memory-usage-limit` | i64 | 128MB | 0 | i64::MAX | Max bytes per bloom object |
| `bloom-use-random-seed` | bool | true | - | - | Random vs fixed seed mode |
| `bloom-defrag-enabled` | bool | true | - | - | Enable defragmentation |

All configs use `ConfigurationFlags::DEFAULT` and have no custom validation callback except for the two string configs (fp-rate and tightening-ratio).

## Integer Configs

**bloom-capacity** - Default initial capacity for auto-created bloom objects. Used by BF.ADD, BF.MADD, and BF.INSERT when creating a new bloom without explicit CAPACITY. Range: 1 to i64::MAX (effectively unlimited). Stored in `BLOOM_CAPACITY: AtomicI64`. Defined as `BLOOM_CAPACITY_DEFAULT = 100`.

**bloom-expansion** - Default expansion factor for scaling. When a sub-filter fills, the next one gets `capacity * expansion` items. Set to 0 for non-scaling behavior. Registration range is 0 to `BLOOM_EXPANSION_MAX as i64` (u32::MAX cast to i64 in the macro). Stored in `BLOOM_EXPANSION: AtomicI64`. Defined as `BLOOM_EXPANSION_DEFAULT = 2`.

The config registration uses `0` as the min (allowing non-scaling), while the command-level `EXPANSION` argument enforces `BLOOM_EXPANSION_MIN` (1) as the floor. The value 0 is only reachable via the config or the `NONSCALING` keyword.

**bloom-memory-usage-limit** - Per-object memory cap in bytes. Default is `128 * 1024 * 1024` (128MB). The `validate_size` function rejects objects whose `memory_usage()` exceeds this value. Write operations that would exceed the limit return `ERR operation exceeds bloom object memory limit`. Stored in `BLOOM_MEMORY_LIMIT_PER_OBJECT: AtomicI64`. Range: 0 to i64::MAX. Setting to 0 effectively blocks all bloom object creation since any object will have size > 0.

## String Configs

**bloom-fp-rate** - Target false positive rate for new bloom objects. Stored as a ValkeyString (`BLOOM_FP_RATE: ValkeyGILGuard<ValkeyString>`) for the config system, with a parallel `BLOOM_FP_RATE_F64: Mutex<f64>` for runtime use. Default: `"0.01"` (1% false positive rate). Range: exclusive (0, 1) - must be strictly greater than `BLOOM_FP_RATE_MIN` (0.0) and strictly less than `BLOOM_FP_RATE_MAX` (1.0).

**bloom-tightening-ratio** - Controls how the FP rate decreases per scale-out. Each new sub-filter uses `fp_rate * tightening_ratio^N` where N is the filter index. Default: `"0.5"`. Range: exclusive (0, 1) using `BLOOM_TIGHTENING_RATIO_MIN` (0.0) and `BLOOM_TIGHTENING_RATIO_MAX` (1.0). Stored as `BLOOM_TIGHTENING_RATIO: ValkeyGILGuard<ValkeyString>` with parallel `BLOOM_TIGHTENING_F64: Mutex<f64>`.

Both string configs exist because the Valkey module configuration system does not natively support f64 types. The string representation is the external interface; the Mutex<f64> is the internal working value.

## Boolean Configs

**bloom-use-random-seed** - When true (default), each new bloom object gets a unique random 32-byte seed. When false, all objects use `FIXED_SEED`. Stored in `BLOOM_USE_RANDOM_SEED: AtomicBool`. `AtomicBool::default()` initializes to false, but the config system applies the default value `true` on module load.

**bloom-defrag-enabled** - Enables cursor-based incremental defragmentation. Default true. Stored in `BLOOM_DEFRAG: AtomicBool` initialized to `AtomicBool::new(BLOOM_DEFRAG_DEFAULT)` (true).

## Custom String Config Handler

The `on_string_config_set` function handles validation for both `bloom-fp-rate` and `bloom-tightening-ratio`:

```rust
pub fn on_string_config_set(
    config_ctx: &ConfigurationContext,
    name: &str,
    val: &'static ValkeyGILGuard<ValkeyString>,
) -> Result<(), ValkeyError> {
    let v = val.get(config_ctx);
    let value_str = v.to_string_lossy();
    let value = match value_str.parse::<f64>() {
        Ok(v) => v,
        Err(_) => return Err(ValkeyError::Str("Invalid floating-point value")),
    };
    match name {
        "bloom-fp-rate" => { /* validate range, update BLOOM_FP_RATE_F64 */ }
        "bloom-tightening-ratio" => { /* validate range, update BLOOM_TIGHTENING_F64 */ }
        _ => Err(ValkeyError::Str("Unknown configuration parameter")),
    }
}
```

The handler performs three steps:

1. **Extract string value**: Gets the ValkeyString from the GIL guard, converts via `to_string_lossy()`
2. **Parse to f64**: Returns `"Invalid floating-point value"` on failure
3. **Validate range**: For `bloom-fp-rate`, out-of-range returns `ERR (0 < error rate range < 1)`. For `bloom-tightening-ratio`, out-of-range returns `ERR (0 < tightening ratio range < 1)`. On success, updates the corresponding `Mutex<f64>` static.

This callback is registered in the `valkey_module!` macro via `Some(Box::new(configs::on_string_config_set))` as the last parameter of each string config entry.

## Config Storage Pattern

The module uses two storage mechanisms from `lazy_static!`:

**AtomicI64 / AtomicBool** for integer and boolean configs:

```rust
pub static ref BLOOM_CAPACITY: AtomicI64 = AtomicI64::new(BLOOM_CAPACITY_DEFAULT);
pub static ref BLOOM_USE_RANDOM_SEED: AtomicBool = AtomicBool::default();
```

These are read with `Ordering::Relaxed` throughout the codebase. The valkey-module SDK handles the CONFIG SET/GET plumbing automatically.

**ValkeyGILGuard + Mutex** for float-as-string configs:

```rust
pub static ref BLOOM_FP_RATE: ValkeyGILGuard<ValkeyString> =
    ValkeyGILGuard::new(ValkeyString::create(None, BLOOM_FP_RATE_DEFAULT));
pub static ref BLOOM_FP_RATE_F64: Mutex<f64> = Mutex::new(0.01);
```

The `ValkeyGILGuard<ValkeyString>` is the config system's storage. The `Mutex<f64>` is kept in sync by `on_string_config_set` and used by command handlers to avoid repeated string parsing.

## module_args_as_configuration

The `valkey_module!` macro includes:

```rust
configurations: [
    // ...
    module_args_as_configuration: true,
]
```

Tells the valkey-module SDK to interpret module load arguments as configuration parameters. For example:

```
valkey-server --loadmodule ./libvalkey_bloom.so bloom-capacity 1000 bloom-fp-rate 0.001
```

The arguments are automatically mapped to the registered configs, eliminating the need for custom `_args` parsing in the `initialize` function. The init function signature accepts `_args: &[ValkeyString]` but does not use them.

## Fixed Seed Constant

```rust
pub const FIXED_SEED: [u8; 32] = [
    89, 15, 245, 34, 234, 120, 17, 218, 167, 20, 216, 9, 59, 62, 123, 217,
    29, 137, 138, 115, 62, 152, 136, 135, 48, 127, 151, 205, 40, 7, 51, 131,
];
```

Used when `bloom-use-random-seed` is false. Also used as the comparison baseline in BF.INSERT's SEED parsing to determine `is_seed_random`.

## Other Constants

- `BLOOM_NUM_FILTERS_PER_OBJECT_LIMIT_MAX: i32 = i32::MAX` - hard cap on sub-filter count per bloom object, checked in `add_item` and `decode_object`
- `BLOOM_MIN_SUPPORTED_VERSION: &[i64; 3] = &[8, 0, 0]` - minimum Valkey server version, checked in `initialize`