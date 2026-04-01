# Testing

Use when writing or running unit tests, integration tests, understanding the test framework, or debugging test failures.

Source: `src/bloom/utils.rs` (tests module), `tests/conftest.py`, `tests/valkey_bloom_test_case.py`, `tests/test_bloom_*.py`

## Contents

- Unit Tests Overview (line 21)
- Parameterized Tests with rstest (line 33)
- Running Unit Tests (line 65)
- Integration Test Framework (line 78)
- Test Base Class Helpers (line 99)
- Test Parameterization (line 129)
- Test File Inventory (line 137)
- Running Integration Tests (line 155)
- Writing New Tests (line 184)

---

## Unit Tests Overview

Unit tests live in `src/bloom/utils.rs` inside a `#[cfg(test)] mod tests` block (approximately lines 722-1308). They test BloomObject and BloomFilter logic directly without a running Valkey server.

Key test helpers defined in the unit test module:

- `random_prefix(len)` - generates a random alphanumeric string for unique item names
- `add_items_till_capacity(bf, capacity, start_idx, prefix, expected_error)` - fills a bloom filter to a target capacity, tracking false positive count. Returns `(fp_count, last_idx)`
- `check_items_exist(bf, start, end, expected, prefix)` - checks existence of items and counts mismatches. Returns `(error_count, num_operations)`
- `fp_assert(error_count, num_ops, expected_fp_rate, margin)` - asserts that the actual false positive rate stays within the expected rate plus a margin
- `verify_restored_items(original, restored, idx, fp_rate, margin, prefix)` - validates that a restored bloom object matches the original in properties, seed, bitmap, and item existence

## Parameterized Tests with rstest

Most unit tests run twice - once with a random seed and once with a fixed seed - using the `rstest` crate:

```rust
#[rstest(
    seed,
    case::random_seed((None, true)),
    case::fixed_seed((Some(configs::FIXED_SEED), false))
)]
fn test_non_scaling_filter(seed: (Option<[u8; 32]>, bool)) {
    // Test body runs for each case
}
```

This pattern verifies that bloom filter behavior is correct regardless of seed mode. Tests parameterized this way:

- `test_non_scaling_filter` - fills a non-scaling filter to capacity, validates FP rate, checks that adding beyond capacity returns `NonScalingFilterFull`, and verifies restore correctness
- `test_scaling_filter` - scales through 5 filter expansions, validates capacity growth, FP rate, and restore correctness

Non-parameterized tests:

- `test_seed` - validates fixed seed produces constant sip keys, random seed produces varying keys
- `test_exceeded_size_limit` - validates that allocations beyond the 128MB memory limit are rejected
- `test_calculate_max_scaled_capacity` - parameterized with `#[rstest]` using `#[case]` attributes across 5 capacity/expansion/fp_rate combinations
- `test_bf_encode_and_decode` - parameterized for scaling (expansion=2) and non-scaling (expansion=0)
- `test_bf_decode_when_unsupported_version_should_failed` - corrupted version byte
- `test_bf_decode_when_bytes_is_empty_should_failed` - empty input
- `test_bf_decode_when_bytes_is_exceed_limit_should_failed` - oversized and invalid fp_rate
- `test_vec_capacity_matches_size_calculations` - validates Vec capacity growth matches expectations
- `test_valid_server_version` - validates version comparison logic against various Valkey versions

## Running Unit Tests

```bash
# Run all unit tests (system allocator required)
cargo test --features enable-system-alloc

# Run a specific test
cargo test --features enable-system-alloc test_scaling_filter

# Run with output visible
cargo test --features enable-system-alloc -- --nocapture
```

## Integration Test Framework

Integration tests use Python's pytest with the `valkey-test-framework` - a framework maintained in `valkey-io/valkey-test-framework`. The framework provides `ValkeyTestCase` and `ReplicationTestCase` base classes that manage Valkey server lifecycle.

Setup (handled by `build.sh` or CI):

1. Build the module as a release `.so`/`.dylib`
2. Clone and compile valkey-server for the target version
3. Clone valkey-test-framework into `tests/build/valkeytestframework/`
4. Install Python requirements (`pip install -r requirements.txt` - installs `valkey` and `pytest==7.4.3`)

The `conftest.py` file adds `tests/build/` and `tests/build/valkeytestframework/` to `sys.path` and configures a pytest fixture that parameterizes all tests with `random-seed` and `fixed-seed` modes:

```python
@pytest.fixture(params=['random-seed', 'fixed-seed'])
def bloom_config_parameterization(request):
    return request.param
```

This means every integration test automatically runs twice - once with `bf.bloom-use-random-seed yes` and once with `no`.

## Test Base Class Helpers

`ValkeyBloomTestCaseBase` (in `tests/valkey_bloom_test_case.py`) extends `ValkeyTestCase` with bloom-specific utilities:

**Server management**:
- `setup_test` fixture - starts a Valkey server with the bloom module loaded and `enable-debug-command` enabled. Also supports external server mode via `VALKEY_EXTERNAL_SERVER=true` with `VALKEY_HOST` and `VALKEY_PORT` environment variables
- `use_random_seed_fixture` - sets `use_random_seed` config based on the parameterization fixture

**Assertion helpers**:
- `verify_error_response(client, cmd, expected_err)` - executes a command expecting a `ResponseError`, asserts the message matches
- `verify_command_success_reply(client, cmd, expected)` - executes a command and asserts the result matches. For BF.M* and BF.INSERT commands, checks result length instead of exact values to avoid FP-related flakiness
- `verify_bloom_filter_item_existence(client, key, value, should_exist)` - checks BF.EXISTS returns expected 0 or 1
- `verify_server_key_count(client, expected)` - asserts DBSIZE matches

**Bloom operation helpers**:
- `create_bloom_filters_and_add_items(client, number_of_bf=5)` - creates N bloom filters named SAMPLE0..N-1 with one item each
- `add_items_till_capacity(client, filter, capacity, start_idx, prefix, batch_size=1000)` - adds items via BF.MADD in batches until target capacity. Returns `(fp_count, last_idx)`
- `add_items_till_nonscaling_failure(client, filter, start_idx, prefix)` - adds items until "non scaling filter is full" error. Returns the failing index
- `check_items_exist(client, filter, start, end, expected, prefix, batch_size=1000)` - checks items via BF.MEXISTS in batches. Returns `(error_count, num_operations)`
- `fp_assert(error_count, num_ops, expected_fp_rate, margin)` - asserts actual FP rate stays within bounds
- `validate_nonscaling_failure(client, filter, prefix, idx)` - validates BF.ADD, BF.MADD, and BF.INSERT all return the expected error. Note: multi-item commands stop at the first error and return 2 elements
- `validate_copied_bloom_correctness(client, filter, prefix, idx, fp_rate, margin, info_dict)` - validates COPY produces identical bloom objects using DEBUG DIGEST-VALUE comparison
- `calculate_expected_capacity(initial, expansion, num_filters)` - computes total capacity across scaled filters
- `generate_random_string(length=7)` - creates a random alphanumeric string

**Metrics helpers**:
- `verify_bloom_metrics(info, memory, objects, filters, items, capacity)` - parses INFO output and validates bloom metric values by prefix-matching metric names
- `parse_valkey_info(section)` - parses an INFO command response into a Python dict
- `restart_external_server(server, ...)` - restarts external Docker-based servers by finding the container by port

## Test Parameterization

Every test class that inherits from `ValkeyBloomTestCaseBase` automatically runs each test method twice (random-seed and fixed-seed) via the `bloom_config_parameterization` fixture from `conftest.py`.

Replication tests inherit from `ReplicationTestCase` (from the test framework) and set up their own `use_random_seed_fixture` to achieve the same parameterization.

Some tests are marked with `@pytest.mark.skip_for_asan` to exclude them from ASAN builds. Currently only `TestBloomDefrag` uses this marker because `activedefrag` cannot be enabled on ASAN server builds.

## Test File Inventory

| File | Tests | Coverage |
|------|-------|----------|
| `test_bloom_basic.py` | 17 | Core operations, COPY, MEMORY USAGE, too-large objects, maxmemory (above/below), module data type, object access, transactions, Lua, DEL/UNLINK/FLUSHALL, TTL, DEBUG, wrong type errors, config set (string/default), DUMP/RESTORE |
| `test_bloom_command.py` | 3 | Command arity validation, error responses for all commands, behavioral edge cases |
| `test_bloom_correctness.py` | 3 | FP rate validation for scaling and non-scaling filters, correctness after COPY |
| `test_bloom_replication.py` | 2 | Replication behavior (write/read/delete/error commands), deterministic replication with non-default configs |
| `test_bloom_save_and_restore.py` | 4 | RDB save/restore (basic, many filters), restore-failed for oversized bloom, non-bloom RDB compatibility |
| `test_bloom_aofrewrite.py` | 2 | AOF rewrite for scaling and non-scaling filters, correctness after reload |
| `test_bloom_metrics.py` | 4 | Basic command metrics, scaled bloomfilter metrics, copy metrics, save-and-restore metrics |
| `test_bloom_keyspace.py` | 1 | Keyspace notifications for bloom.add and bloom.reserve events |
| `test_bloom_acl_category.py` | 2 | ACL category "bloom" enforcement, allowed/denied command lists |
| `test_bloom_defrag.py` | 1 | Active defragmentation hits/misses metrics (parametrized with capacity 1 and 200, marked skip_for_asan) |
| `test_bloom_valkeypy_compatibility.py` | 5 | valkey-py client compatibility for BF.RESERVE, BF.ADD, BF.MADD, BF.EXISTS, BF.MEXISTS, BF.INFO, BF.INSERT, BF.CARD |

Total: 11 test files, 44 test methods, ~1782 lines of test code (excluding base class). Each test runs twice (random-seed and fixed-seed), so a full run executes 88 test instances per server version.

## Running Integration Tests

```bash
# Full suite via build.sh
export SERVER_VERSION=unstable
./build.sh

# Manual pytest (after build.sh has set up server and framework)
export MODULE_PATH=$(pwd)/target/release/libvalkey_bloom.so
python3 -m pytest --cache-clear -v tests/

# Run specific test file
python3 -m pytest --cache-clear -v tests/test_bloom_replication.py

# Run specific test by name pattern
python3 -m pytest --cache-clear -v tests/ -k "test_deterministic"

# With ASAN leak detection (via build.sh)
export ASAN_BUILD=1
export SERVER_VERSION=unstable
./build.sh

# Against an external server (e.g., Docker)
export VALKEY_EXTERNAL_SERVER=true
export VALKEY_HOST=localhost
export VALKEY_PORT=6379
python3 -m pytest --cache-clear -v tests/
```

## Writing New Tests

1. Create a new test class inheriting from `ValkeyBloomTestCaseBase` (or `ReplicationTestCase` for replication tests)
2. The `setup_test` and `use_random_seed_fixture` fixtures are `autouse=True` - they run automatically
3. Use `self.client` for the primary connection and `self.server` for server operations
4. Use the batch helpers (`add_items_till_capacity`, `check_items_exist`) for correctness tests to keep tests fast
5. Use `self.verify_error_response` for testing error paths
6. For replication tests, call `self.setup_replication(num_replicas=1)` in the test method, then use `self.replicas[0].client` for replica operations
7. If the test is incompatible with ASAN builds, mark the class with `@pytest.mark.skip_for_asan(reason="...")`

## See Also

- `reference/contributing/build.md` - build system and feature flags
- `reference/contributing/ci-pipeline.md` - CI pipeline configuration
- `reference/architecture/bloom-object.md` - FP rate tightening and scaling behavior tested by correctness tests
