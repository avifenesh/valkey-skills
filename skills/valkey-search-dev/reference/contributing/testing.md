# Testing

Use when running tests, adding new test cases, understanding the test infrastructure, or debugging test failures.

Source: `testing/CMakeLists.txt`, `testing/`, `testing/integration/`, `integration/`, `build.sh`

## Contents

- [Test Tiers](#test-tiers)
- [Unit Tests](#unit-tests)
- [Python Integration Tests](#python-integration-tests)
- [Stability and Endurance Tests](#stability-and-endurance-tests)
- [Test Output and Debugging](#test-output-and-debugging)
- [Adding a New Test](#adding-a-new-test)

## Test Tiers

valkey-search has three test tiers:

| Tier | Framework | Location | What it tests |
|------|-----------|----------|---------------|
| Unit tests | GoogleTest (C++) | `testing/` | Individual components in isolation with mocked Valkey API |
| Integration tests (Python) | pytest | `integration/` | Full module loaded into a real Valkey server |
| Stability / endurance tests | Python + memtier_benchmark | `testing/integration/` | Long-running load and stability with memtier_benchmark |

## Unit Tests

### Test Binaries

The `testing/CMakeLists.txt` groups test source files into seven binaries:

| Binary | Test Files | Scope |
|--------|-----------|-------|
| `commands_test` | FT.CREATE/SEARCH/AGGREGATE/DROPINDEX/INFO/LIST parsers, filter, FT.INTERNAL_UPDATE | Command parsing and execution |
| `indexes_test` | index_schema, numeric, tag, text, vector, lexer, posting | Index data structures and operations |
| `core_test` | valkey_search, schema_manager, keyspace_event_manager, server_events, attribute_data_type, MULTI/EXEC, vector_externalizer, ACL, RDB serialization | Core module lifecycle |
| `query_test` | search, response_generator | Query execution and result formatting |
| `coordinator_test` | metadata_manager, client | gRPC coordinator communication |
| `valkey_utils_test` | allocator, intrusive_list, intrusive_ref_count, LRU, patricia_tree, segment_tree, string_interning | Utility data structures |
| `text_index_test` | flat_position_map, radix, rax_wrapper, text_index_schema | Full-text index internals |

### Test Infrastructure

Tests use `testing/common.h` and `testing/common.cc` which provide:

- Mocked `ValkeyModuleCtx` and `ValkeyModuleString` via VMSDK's testing infrastructure (`vmsdk/src/testing_infra/`)
- Helper functions for creating index schemas and test data
- A shared `testing_common_base` static library linked by all test binaries
- A `testing_common_coordinator` interface library for tests needing coordinator functionality

### Running Unit Tests

```bash
# Build and run all unit tests
./build.sh --run-tests

# Run a specific test binary
./build.sh --run-tests=commands_test

# Run with verbose output on failure
./build.sh --run-tests --test-errors-stdout

# Run with AddressSanitizer
./build.sh --asan --run-tests

# Run with ThreadSanitizer
./build.sh --tsan --run-tests
```

Test binaries are placed in `.build-release/tests/` (or the corresponding build directory). You can also run them directly:

```bash
.build-release/tests/indexes_test --gtest_brief=1
.build-release/tests/commands_test --gtest_filter="*FTCreate*"
```

Test output is logged to `.build-release/tests.out`. Individual test output goes to `.build-release/current_test.out` during execution.

### Sanitizer Behavior

When running with `--asan` or `--tsan`, the test runner does not stop at the first failure. All test binaries run to completion so the full set of sanitizer reports can be collected. The script exits with a non-zero code if any test failed.

## Python Integration Tests

Located in `integration/`, these tests load `libsearch.so` into a real Valkey server process and exercise commands end-to-end.

### Test Categories

| File Pattern | What it tests |
|-------------|---------------|
| `test_vss_basic.py` | Vector similarity search fundamentals |
| `test_fulltext*.py` | Full-text search, space performance, inflight blocking |
| `test_ft_create*.py` | Index creation and consistency |
| `test_ft_dropindex*.py` | Index deletion and consistency |
| `test_postfilter.py` | Post-filter expression evaluation |
| `test_filter_expressions.py` | Pre-filter predicates |
| `test_saverestore.py`, `test_endurance_save_restore.py` | RDB persistence round-trips |
| `test_json_operations.py`, `test_cross_module_compat.py` | JSON module cross-compatibility |
| `test_oom_handling.py` | Out-of-memory behavior |
| `test_valkey_search_acl.py` | ACL permission enforcement |
| `test_multidb_search.py`, `test_dbnum.py` | Multi-database search |
| `test_info*.py` | FT.INFO output, cluster info, primary info |
| `test_eviction.py`, `test_expired.py` | Key eviction and expiration handling |
| `test_copy.py` | Key copy behavior |
| `test_multi_lua.py` | MULTI/EXEC and Lua script interactions |
| `test_rdb_load_*.py` | RDB compatibility (v1.0, without module) |
| `test_cancel.py` | Query cancellation |
| `test_debug.py` | FT._DEBUG command |
| `test_non_vector.py` | Non-vector field queries |
| `test_query_parser.py` | Query parsing edge cases |
| `test_aggregate_metrics.py` | FT.AGGREGATE metrics |
| `test_flushall.py` | FLUSHALL behavior |
| `test_singleslot.py` | Single-slot query behavior |
| `test_versioning.py` | Module versioning |
| `compatibility/` | Cross-version compatibility tests |

### Running Integration Tests

```bash
# Build and run all integration tests
./build.sh --run-integration-tests

# Run with a pattern filter
./build.sh --run-integration-tests=test_vss_basic

# Run only OSS integration tests (skips stability tests)
./build.sh --run-integration-tests=oss

# Run with retries
./build.sh --run-integration-tests --retries=3

# Run with ASan
./build.sh --asan --run-integration-tests
```

### Integration Test Infrastructure

The `integration/run.sh` script:

1. Locates `valkey-server` binary (downloads if needed via `setup_valkey_server`)
2. Locates the `valkey-json` module for cross-module tests
3. Creates a Python virtual environment and installs test dependencies
4. Runs pytest against `integration/` with optional pattern filtering
5. After sanitizer runs, terminates the server and checks server logs for ASan/TSan errors

Key environment variables used by tests:

| Variable | Purpose |
|----------|---------|
| `MODULE_PATH` | Path to `libsearch.so` |
| `VALKEY_SERVER_PATH` | Path to `valkey-server` binary |
| `JSON_MODULE_PATH` | Path to `libjson.so` for cross-module tests |
| `LOGS_DIR` | Server log output directory |
| `TEST_PATTERN` | pytest `-k` filter expression |
| `INTEG_RETRIES` | Number of retry attempts for flaky tests |
| `PYTEST_CAPTURE_DISABLED` | Set to `1` to disable pytest output capture |

The base test class `valkey_search_test_case.py` handles server startup, module loading, and cleanup.

## Stability and Endurance Tests

Located in `testing/integration/`, these are Python scripts that use `memtier_benchmark` for sustained load generation against a Valkey server with the search module loaded:

- `vector_search_integration_test.py` - vector search integration under load
- `stability_test.py` - long-running stability under sustained write/read traffic
- `ft_internal_update_integration_test.py` - FT.INTERNAL_UPDATE replication under load

The `testing/integration/run.sh` script:

1. Builds a Python virtual environment in the build directory
2. Sets up the Valkey server and JSON module binaries
3. Verifies `memtier_benchmark` is available in PATH
4. Runs the selected test with server process management
5. For sanitizer builds, terminates the server and checks logs for ASan/TSan errors

Key environment variables:

| Variable | Purpose |
|----------|---------|
| `MEMTIER_PATH` | Path to memtier_benchmark binary |
| `VALKEY_SEARCH_PATH` | Path to `libsearch.so` |
| `TEST_UNDECLARED_OUTPUTS_DIR` | Directory for test output artifacts |
| `TEST_TMPDIR` | Temporary directory for test working files |

```bash
# Run stability tests (from testing/integration/)
cd testing/integration && ./run.sh --test stability

# Run vector search integration test
cd testing/integration && ./run.sh --test vector_search_integration

# Run with sanitizer
cd testing/integration && ./run.sh --asan
```

When running with sanitizers, only `vector_search_integration` is supported.

## Test Output and Debugging

### Unit Test Output

- All output: `.build-release/tests.out`
- Per-test output during execution: `.build-release/current_test.out`
- Use `--test-errors-stdout` to dump failed test output to the terminal

### Integration Test Output

- Server logs: `.build-release/integration/.valkey-test-framework/`
- Use `--capture` flag with `integration/run.sh` to disable pytest output capture and see `print()` statements in real-time
- Set `PYTEST_CAPTURE_DISABLED=1` environment variable for the same effect

### Common Debugging Patterns

```bash
# Run a single integration test with verbose output
cd integration && TEST_PATTERN=test_vss_basic ./run.sh --capture

# Run a unit test with GTest filter and full output
.build-release/tests/indexes_test --gtest_filter="*NumericIndex*" --gtest_print_time=1

# Debug a failing test under GDB
gdb --args .build-release/tests/core_test --gtest_filter="*SchemaManager*"
```

## Adding a New Test

### Unit Test

1. Create `testing/<component>_test.cc` (or add to an existing file in the appropriate suite)
2. Include `testing/common.h` for test infrastructure
3. Add the source file to the appropriate test binary in `testing/CMakeLists.txt`
4. Link any additional libraries the test needs
5. Verify the test passes under both normal and sanitizer builds

### Integration Test

1. Create `integration/test_<feature>.py`
2. Import from `valkey_search_test_case.py` for the base class
3. Use `utils.py` helpers for server setup and command execution
4. Tests are auto-discovered by pytest - no registration needed
5. Ensure proper cleanup of server processes and temporary files
