# Testing

Use when running tests, adding test cases, or debugging failures.

Source: `testing/`, `testing/CMakeLists.txt`, `testing/integration/`, `integration/`, `build.sh`.

## Tiers

| Tier | Framework | Location | Scope |
|------|-----------|----------|-------|
| Unit | GoogleTest (C++) | `testing/` | components in isolation w/ mocked Valkey API |
| Integration | pytest | `integration/` | full module loaded into real Valkey |
| Stability | Python + `memtier_benchmark` | `testing/integration/` | sustained load |

## Unit tests

### Binaries

`testing/CMakeLists.txt` groups sources into 7 binaries:

| Binary | Scope |
|--------|-------|
| `commands_test` | FT.CREATE / SEARCH / AGGREGATE / DROPINDEX / INFO / LIST parsers, filter, INTERNAL_UPDATE |
| `indexes_test` | index_schema, numeric, tag, text, vector, lexer, posting |
| `core_test` | valkey_search, schema_manager, keyspace_event_manager, server_events, attribute_data_type, MULTI/EXEC, vector_externalizer, ACL, RDB |
| `query_test` | search, response_generator |
| `coordinator_test` | metadata_manager, client |
| `valkey_utils_test` | allocator, intrusive_list, intrusive_ref_count, LRU, patricia_tree, segment_tree, string_interning |
| `text_index_test` | flat_position_map, radix, rax_wrapper, text_index_schema |

### Infrastructure

`testing/common.{h,cc}` provides mocked `ValkeyModuleCtx`/`ValkeyModuleString` via VMSDK's `vmsdk/src/testing_infra/`, index-schema/test-data helpers. Shared `testing_common_base` static library linked by all test binaries. `testing_common_coordinator` interface library for coordinator-needing tests.

### Running

```bash
./build.sh --run-tests                              # all
./build.sh --run-tests=commands_test                # one binary
./build.sh --run-tests --test-errors-stdout         # print failed output
./build.sh --asan --run-tests
./build.sh --tsan --run-tests
```

Binaries under `.build-release/tests/`. Direct invocation:

```bash
.build-release/tests/indexes_test --gtest_brief=1
.build-release/tests/commands_test --gtest_filter="*FTCreate*"
```

Output at `.build-release/tests.out`. Per-test during exec at `.build-release/current_test.out`.

Under `--asan` / `--tsan` the runner continues past failures (collect full report set); exits non-zero if any failed. Google Benchmark disabled for SAN.

## Integration tests (Python)

In `integration/`. Load `libsearch.so` into a real Valkey process and exercise commands end-to-end.

### Coverage

| File | Covers |
|------|--------|
| `test_vss_basic.py` | vector similarity search fundamentals |
| `test_fulltext*.py` | full-text search, space performance, inflight blocking |
| `test_ft_create*.py` | index creation and consistency |
| `test_ft_dropindex*.py` | index deletion and consistency |
| `test_postfilter.py` | post-filter expression evaluation |
| `test_filter_expressions.py` | pre-filter predicates |
| `test_non_vector.py` | non-vector field queries |
| `test_query_parser.py` | query parsing edge cases |
| `test_saverestore.py`, `test_endurance_save_restore.py` | RDB persistence round-trips |
| `test_rdb_load_*.py` | RDB compatibility (v1.0, without module) |
| `test_json_operations.py`, `test_cross_module_compat.py` | JSON module cross-compatibility |
| `test_oom_handling.py` | out-of-memory behavior |
| `test_eviction.py`, `test_expired.py` | key eviction and expiration |
| `test_copy.py` | key copy behavior |
| `test_multi_lua.py` | MULTI/EXEC and Lua interactions |
| `test_flushall.py` | FLUSHALL behavior |
| `test_cancel.py` | query cancellation |
| `test_debug.py` | FT._DEBUG command |
| `test_aggregate_metrics.py` | FT.AGGREGATE metrics |
| `test_info*.py` | FT.INFO (cluster, primary, local) |
| `test_multidb_search.py`, `test_dbnum.py` | multi-database |
| `test_singleslot.py` | single-slot query behavior |
| `test_versioning.py` | module versioning |
| `test_valkey_search_acl.py` | ACL permission enforcement |
| `compatibility/` | cross-version compatibility subtree |

### Running

```bash
./build.sh --run-integration-tests
./build.sh --run-integration-tests=test_vss_basic
./build.sh --run-integration-tests=oss           # skip stability
./build.sh --run-integration-tests --retries=3
./build.sh --asan --run-integration-tests
```

### `integration/run.sh` flow

1. Locate `valkey-server` (download via `setup_valkey_server` if needed).
2. Locate `valkey-json` module for cross-module tests.
3. Python venv + install deps.
4. pytest against `integration/` with optional `-k` filter.
5. Under SAN - terminate server, grep logs for ASan/TSan errors.

### Env

| Var | Use |
|-----|-----|
| `MODULE_PATH` | `libsearch.so` |
| `VALKEY_SERVER_PATH` | `valkey-server` |
| `JSON_MODULE_PATH` | `libjson.so` for cross-module |
| `LOGS_DIR` | server log dir |
| `TEST_PATTERN` | pytest `-k` filter |
| `INTEG_RETRIES` | flaky retry count |
| `PYTEST_CAPTURE_DISABLED` | `1` disables capture |

Base class `valkey_search_test_case.py` handles server startup, module loading, cleanup.

## Stability / endurance (`testing/integration/`)

- `vector_search_integration_test.py` - vector search under load.
- `stability_test.py` - long-running sustained write/read.
- `ft_internal_update_integration_test.py` - INTERNAL_UPDATE replication under load.

`testing/integration/run.sh`:

1. Build Python venv in build dir.
2. Set up server + JSON module binaries.
3. Require `memtier_benchmark` in PATH.
4. Run selected test with server process management.
5. SAN builds - terminate + grep logs.

```bash
cd testing/integration && ./run.sh --test stability
cd testing/integration && ./run.sh --test vector_search_integration
cd testing/integration && ./run.sh --asan    # only vector_search_integration supported under SAN
```

| Env | Use |
|-----|-----|
| `MEMTIER_PATH` | memtier binary |
| `VALKEY_SEARCH_PATH` | `libsearch.so` |
| `TEST_UNDECLARED_OUTPUTS_DIR` | artifacts |
| `TEST_TMPDIR` | working files |

## Debugging

```bash
cd integration && TEST_PATTERN=test_vss_basic ./run.sh --capture
.build-release/tests/indexes_test --gtest_filter="*NumericIndex*" --gtest_print_time=1
gdb --args .build-release/tests/core_test --gtest_filter="*SchemaManager*"
```

Integration server logs: `.build-release/integration/.valkey-test-framework/`. Use `--capture` with `integration/run.sh` (or `PYTEST_CAPTURE_DISABLED=1`) for real-time `print()`.

## Adding a test

### Unit

1. `testing/<component>_test.cc` (or append to existing).
2. Include `testing/common.h`.
3. Add source to the appropriate binary in `testing/CMakeLists.txt`.
4. Link any extra libs.
5. Verify under normal + SAN builds.

### Integration

1. `integration/test_<feature>.py`.
2. Import from `valkey_search_test_case.py`.
3. Use `utils.py` helpers.
4. pytest auto-discovery (no registration).
5. Clean up processes + temp files.
