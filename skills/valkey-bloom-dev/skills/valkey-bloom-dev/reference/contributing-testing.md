# Testing

Use when writing or running unit / integration tests, or understanding the seed parameterization pattern.

Source: `src/bloom/utils.rs` (`#[cfg(test)] mod tests`), `tests/conftest.py`, `tests/valkey_bloom_test_case.py`, `tests/test_bloom_*.py`.

## Unit tests (Rust)

Live in a `#[cfg(test)] mod tests` block in `src/bloom/utils.rs`. Exercise `BloomObject` / `BloomFilter` without a running server.

**Must run with `--features enable-system-alloc`** - ValkeyAlloc needs a running Valkey:

```bash
cargo test --features enable-system-alloc
cargo test --features enable-system-alloc test_scaling_filter
cargo test --features enable-system-alloc -- --nocapture
```

### rstest seed parameterization

Most tests run twice (random + fixed seed) via `rstest`:

```rust
#[rstest(
    seed,
    case::random_seed((None, true)),
    case::fixed_seed((Some(configs::FIXED_SEED), false))
)]
fn test_non_scaling_filter(seed: (Option<[u8; 32]>, bool)) { ... }
```

Parameterized tests (each runs twice): `test_non_scaling_filter`, `test_scaling_filter`.

Non-parameterized (seed-irrelevant): `test_seed` (constant vs varying sip keys), `test_exceeded_size_limit`, `test_calculate_max_scaled_capacity` (rstest `#[case]`s for capacity/expansion/fp combos), `test_bf_encode_and_decode` (scaling vs non-scaling), `test_bf_decode_when_*_should_failed` (unsupported version / empty / oversized + invalid fp), `test_vec_capacity_matches_size_calculations`, `test_valid_server_version`.

### Unit test helpers

Defined inside the test module:

- `random_prefix(len)` - unique item names
- `add_items_till_capacity(bf, capacity, start_idx, prefix, expected_error)` -> `(fp_count, last_idx)`
- `check_items_exist(bf, start, end, expected, prefix)` -> `(error_count, num_operations)`
- `fp_assert(error_count, num_ops, expected_fp_rate, margin)`
- `verify_restored_items(original, restored, idx, fp_rate, margin, prefix)` - validates restore round-trip (properties, seed, bitmap, item existence)

## Integration tests (Python)

Pytest + `valkey-test-framework` (maintained in `valkey-io/valkey-test-framework`). `ValkeyTestCase` and `ReplicationTestCase` manage server lifecycle.

`conftest.py` adds `tests/build/` and `tests/build/valkeytestframework/` to `sys.path` and defines the autouse parameterization:

```python
@pytest.fixture(params=['random-seed', 'fixed-seed'])
def bloom_config_parameterization(request):
    return request.param
```

Every integration test runs twice - random-seed and fixed-seed - mirroring the unit tests.

### Base class helpers (`ValkeyBloomTestCaseBase` in `tests/valkey_bloom_test_case.py`)

Extends `ValkeyTestCase`. Key fixtures: `setup_test` (starts Valkey + loads module + `enable-debug-command`; also supports external server via `VALKEY_EXTERNAL_SERVER=true` + `VALKEY_HOST`/`VALKEY_PORT`), `use_random_seed_fixture` (sets `use_random_seed` from the parameterization).

Notable helpers:

- `verify_error_response`, `verify_command_success_reply`, `verify_bloom_filter_item_existence`, `verify_server_key_count`
- `create_bloom_filters_and_add_items`, `add_items_till_capacity` (via MADD batches), `add_items_till_nonscaling_failure`, `check_items_exist` (MEXISTS batches), `fp_assert`
- `validate_nonscaling_failure` - asserts BF.ADD, BF.MADD, BF.INSERT all return the expected error; multi-item commands stop at first error (2 result elements)
- `validate_copied_bloom_correctness` - uses `DEBUG DIGEST-VALUE` to confirm COPY produces identical objects
- `verify_bloom_metrics`, `parse_valkey_info`, `restart_external_server`

### Test files

| File | Tests | Coverage |
|------|-------|----------|
| `test_bloom_basic.py` | 17 | core ops, COPY, MEMORY USAGE, maxmemory, type, transactions, Lua, DEL/UNLINK/FLUSHALL, TTL, DEBUG, wrong-type, CONFIG SET, DUMP/RESTORE |
| `test_bloom_command.py` | 3 | arity and error responses across commands |
| `test_bloom_correctness.py` | 3 | FP rate (scaling / non-scaling), correctness after COPY |
| `test_bloom_replication.py` | 2 | write / read / delete / error + deterministic replication with non-default configs |
| `test_bloom_save_and_restore.py` | 4 | RDB (basic, many filters), oversized bloom failure, non-bloom RDB compat |
| `test_bloom_aofrewrite.py` | 2 | AOF rewrite (scaling + non-scaling), correctness after reload |
| `test_bloom_metrics.py` | 4 | basic / scaled / copy / save-restore metrics |
| `test_bloom_keyspace.py` | 1 | `bloom.add` / `bloom.reserve` events |
| `test_bloom_acl_category.py` | 2 | `bloom` ACL category allow / deny |
| `test_bloom_defrag.py` | 1 | defrag hits / misses, parameterized on capacity; **marked `skip_for_asan`** |
| `test_bloom_valkeypy_compatibility.py` | 5 | valkey-py compatibility across BF.* |

11 files, 44 methods, ~1782 lines. Doubled by seed parameterization -> 88 instances per server version.

### ASAN

`@pytest.mark.skip_for_asan(reason=...)` excludes tests under CI's `-m "not skip_for_asan"`. Only `TestBloomDefrag` uses it currently (`activedefrag` can't run under ASAN builds).

### Running integration tests

```bash
# Full suite (build.sh handles setup)
export SERVER_VERSION=unstable
./build.sh

# Manual (after setup done)
export MODULE_PATH=$(pwd)/target/release/libvalkey_bloom.so
python3 -m pytest --cache-clear -v tests/
python3 -m pytest -v tests/ -k "test_deterministic"

# External server (e.g. Docker)
export VALKEY_EXTERNAL_SERVER=true VALKEY_HOST=localhost VALKEY_PORT=6379
python3 -m pytest -v tests/
```

## Writing new tests

1. Extend `ValkeyBloomTestCaseBase` (or `ReplicationTestCase`). Both autouse fixtures handle server + seed mode.
2. Use batch helpers (`add_items_till_capacity`, `check_items_exist`) to keep runtime down.
3. Replication: call `self.setup_replication(num_replicas=1)` inside the test; replica client via `self.replicas[0].client`.
4. ASAN-incompatible -> `@pytest.mark.skip_for_asan(reason="...")`.
