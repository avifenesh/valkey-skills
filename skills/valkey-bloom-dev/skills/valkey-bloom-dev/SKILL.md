---
name: valkey-bloom-dev
description: "Use when contributing to valkey-io/valkey-bloom source - Rust bloom filter internals, scaling, persistence (RDB/AOF), replication, build, tests, CI, or reviewing module PRs. Not for using BF commands in apps (valkey) or Valkey server internals (valkey-dev)."
version: 2.0.0
argument-hint: "[area or task]"
---

# valkey-bloom contributor reference

Targets valkey-bloom 1.0.1. Module registers itself as `bf` (not `bloom`). All Rust, loaded as `libvalkey_bloom.{so,dylib}`.

## Not this skill

- Apps calling BF.ADD / BF.EXISTS -> use `valkey`.
- Valkey server internals -> use `valkey-dev`.

## Route by work area

| Working on... | File |
|---------------|------|
| BloomObject struct, scale-out sequence, FP tightening, memory-limit validators, VALIDATESCALETO / MAXSCALEDCAPACITY, accessors, Drop | `reference/architecture-bloom-object.md` |
| BloomFilter struct, `bloomfilter` crate (3.0.1), seed modes (random / FIXED_SEED), per-filter add/check, sizing, COPY deep-copy | `reference/architecture-bloom-filter.md` |
| RDB save format and load validation, AOF rewrite via BF.LOAD, bincode encode/decode, version bytes, COPY callback, AUX ignore, BLOOM_TYPE registration | `reference/architecture-persistence.md` |
| 5-layer defrag order, cursor-incremental resume, DEFRAG_BLOOM_FILTER swap placeholder, `external_vec_defrag`, `bloom-defrag-enabled`, INFO bf sections, 7 atomic counters | `reference/architecture-defrag-metrics.md` |
| BF.ADD / BF.MADD / BF.EXISTS / BF.MEXISTS / BF.CARD / BF.INFO handlers, auto-creation defaults, `handle_bloom_add` multi-mode, INFO field table, command flags and ACL | `reference/commands-command-handlers.md` |
| BF.RESERVE / BF.INSERT argument parsing, TIGHTENING and SEED replication-internal args, VALIDATESCALETO check, NOCREATE, internal BF.LOAD, error summary | `reference/commands-bf-reserve-insert.md` |
| Deterministic replication, three cases, synthetic BF.INSERT form, ReplicateArgs, must_obey_client (8.0 vs 8.1+), size-limit bypass, keyspace events | `reference/commands-replication.md` |
| 7 module configs (defaults + ranges), string-as-f64 pattern, `on_string_config_set`, storage (AtomicI64 vs ValkeyGILGuard + Mutex<f64>), FIXED_SEED, BLOOM_MIN_SUPPORTED_VERSION, `module_args_as_configuration` | `reference/commands-module-configs.md` |
| Cargo setup (cdylib, `valkey_bloom`), feature flags (`enable-system-alloc`, `valkey_8_0`), ValkeyAlloc, `build.sh` env vars, build.sh vs CI differences | `reference/contributing-build.md` |
| Unit tests (rstest seed parameterization), integration tests (pytest + valkey-test-framework), base class helpers, test inventory, ASAN skip, running tests | `reference/contributing-testing.md` |
| CI jobs (ubuntu / macos / asan), matrix, LeakSanitizer detection scan, release-trigger workflow dispatching to valkey-bundle, debug tips | `reference/contributing-ci-pipeline.md` |
| Directory layout, `valkey_module!` registration, command registration pattern, command JSON metadata, `BloomError` enum + error strings, adding a new command | `reference/contributing-code-structure.md` |

## Critical rules

1. **ValkeyAlloc is the global allocator.** Unit tests fail without `--features enable-system-alloc`.
2. **Seeds must be deterministic for replication.** Primary replicates creation as a synthetic `BF.INSERT ... TIGHTENING <r> SEED <32 bytes> ...` so the replica's filter hashes identically.
3. **Size limit is primary-only.** When `must_obey_client(ctx)` is true (replica / AOF replay), `validate_size_limit` is false - replicas must accept whatever the primary accepted.
4. **`valkey_8_0` feature flag swaps `must_obey_client`** from `ValkeyModule_MustObeyClient` (8.1+) to `ContextFlags::REPLICATED` fallback.
5. **AOF rewrite emits BF.LOAD; replication emits synthetic BF.INSERT** - two different paths. Don't conflate.
6. **All sub-filters in an object share the first filter's seed.** `BloomObject::seed()` returns `filters[0].seed()`. Scale-out uses `with_fixed_seed(self.seed())`.

## Grep hazards

Names that differ from similar modules or that an agent might get wrong:

- **Module name is `bf`, not `bloom`**. `MODULE_NAME = "bf"`, ACL category is `"bloom"`, data type is `"bloomfltr"` (9 chars, max). Configs prefixed with `bf.` in `CONFIG SET`.
- `MODULE_VERSION = 999999` on dev, Cargo version `99.99.99-dev`. Both rewritten at release. `MODULE_RELEASE_STAGE` runs `"dev"` -> `"rc1"..` -> `"ga"`.
- `BLOOM_TYPE_ENCODING_VERSION` (RDB encver) and `BLOOM_OBJECT_VERSION` (bincode prefix) are **distinct**, both currently 1. Bumping rules: `BLOOM_OBJECT_VERSION` bumps when `BloomObject` struct layout changes; `BLOOM_TYPE_ENCODING_VERSION` bumps when RDB field layout changes.
- `BLOOM_NUM_FILTERS_PER_OBJECT_LIMIT_MAX = i32::MAX` - the hard filter-count ceiling. 128 MB memory limit hits first in practice.
- `BLOOM_MIN_SUPPORTED_VERSION = &[8, 0, 0]` - module refuses to load on Valkey 7.x.
- `expansion == 0` is the in-memory representation of `NONSCALING`. Config register-range allows 0; command-level `EXPANSION` arg enforces `>= 1`.
- Seed RDB-load check: `!is_seed_random && filter.seed() != FIXED_SEED` aborts load. Catches mismatched `FIXED_SEED` constants across builds.
- RDB per-filter layout stores `num_items` **only for the last filter**; others are assumed `num_items == capacity`. Don't add `num_items` reads in a straight loop.
- `on_string_config_set` handles both `bloom-fp-rate` and `bloom-tightening-ratio` - paired with `BLOOM_FP_RATE_F64` / `BLOOM_TIGHTENING_F64` `Mutex<f64>` caches to avoid repeated string parsing.
- `module_args_as_configuration: true` means load args feed the config system - `initialize`'s `_args: &[ValkeyString]` is unused by design.
- `extern "C"` callbacks live in `src/wrapper/bloom_callback.rs`, not alongside the type definitions in `src/bloom/`.
- **Vec defrag counter bug**: step 4 of defrag (the `Vec<Box<BloomFilter>>` backing array) increments `BLOOM_DEFRAG_HITS` in **both** branches instead of splitting hits/misses. Known source issue.
- BF.LOAD is the only write command without the `fast` flag (`"write deny-oom"`). It deserializes a full bloom.
- `ValidateScaleToExceedsMaxSize` and `ValidateScaleToFalsePositiveInvalid` errors are produced by `calculate_max_scaled_capacity` during BF.INSERT's VALIDATESCALETO check. Not replicated.
- `DEFRAG_BLOOM_FILTER` is a global `lazy_static Mutex<Option<Box<Bloom<[u8]>>>>` used only as a swap placeholder during defrag of the inner bloom pointer. Don't interpret it as live state.

## Quick-start

```bash
cargo build --release                               # Valkey 8.1+
cargo build --release --features valkey_8_0         # Valkey 8.0
cargo test --features enable-system-alloc           # unit tests
valkey-server --loadmodule ./target/release/libvalkey_bloom.so
python3 -m pytest tests/ -v                         # integration (needs build.sh setup)
```

Commands: BF.ADD, BF.MADD, BF.EXISTS, BF.MEXISTS, BF.CARD, BF.RESERVE, BF.INFO, BF.INSERT, BF.LOAD.

Configs: `bloom-capacity` (100), `bloom-expansion` (2), `bloom-fp-rate` ("0.01"), `bloom-tightening-ratio` ("0.5"), `bloom-memory-usage-limit` (128 MB), `bloom-use-random-seed` (true), `bloom-defrag-enabled` (true).
