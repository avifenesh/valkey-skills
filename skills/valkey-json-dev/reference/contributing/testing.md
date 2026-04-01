# Test Infrastructure

Use when writing tests, understanding test structure, debugging test failures, or adding test coverage in valkey-json.

Source: `tst/unit/`, `tst/integration/`, `tst/unit/CMakeLists.txt` in valkey-io/valkey-json

## Contents

- [Unit Tests (GoogleTest)](#unit-tests-googletest)
- [Integration Tests (pytest)](#integration-tests-pytest)

## Unit Tests (GoogleTest)

All unit tests compile into a single `unitTests` binary using GoogleTest and GoogleMock. Defined in `tst/unit/CMakeLists.txt` - the binary links against `libjson` (the module library) plus `GTest::gtest_main` and `GTest::gmock_main`.

### Unit Test Files

| File | Tests |
|------|-------|
| `dom_test.cc` | JDocument/JValue DOM operations - create, modify, query, serialize, reply buffer formatting |
| `selector_test.cc` | JSONPath v1/v2 selector - path parsing, recursive descent, filters, slices, wildcards |
| `keytable_test.cc` | KeyTable string interning - PtrWithMetaData, shard distribution, hash functions, ref counting |
| `json_test.cc` | High-level JSON operations - stats init, alloc setup, end-to-end document workflows |
| `hashtable_test.cc` | Object hash table internals - insert, lookup, resize, collision handling |
| `stats_test.cc` | Statistics subsystem - bucket finding, histogram boundaries, metric tracking |
| `traps_test.cc` | Memory trap system - allocation validation, corruption detection |
| `util_test.cc` | Utility functions - number formatting, string helpers, module pointer setup |

### Module Simulation Layer

Unit tests run without a real Valkey server. The `module_sim.h`/`module_sim.cc` files provide:

- **Memory tracking** - `test_malloc`, `test_free`, `test_realloc` track every allocation in a `std::map<void*, size_t>` to catch leaks and double-frees
- **`malloced` counter** - global byte counter; tests assert it returns to zero after cleanup
- **`test_malloc_size`** - returns the size of a tracked allocation (replaces `zmalloc_size`)
- **`setupValkeyModulePointers()`** - wires up function pointers that the module code calls through the ValkeyModule API
- **`test_log`** - captures log output for assertion (`test_getLogText()`)

The simulation stubs let DOM, selector, keytable, and allocator code run in isolation. Tests that need reply formatting use `getReplyString()` and `cs_replyWithBuffer()` from `dom_test.cc`.

### Running Unit Tests

```bash
# Build and run all unit tests
./build.sh --unit

# Run directly after building
./build/tst/unit/unitTests

# Run specific test suite
./build/tst/unit/unitTests --gtest_filter="SelectorTest.*"

# Run single test
./build/tst/unit/unitTests --gtest_filter="DomTest.testSetGet"

# List available tests
./build/tst/unit/unitTests --gtest_list_tests
```

CTest discovers tests automatically with the `unit_` prefix. Each test has a 10-second timeout.

### Writing Unit Tests

Follow the existing patterns:

```cpp
#include <gtest/gtest.h>
#include "json/dom.h"
#include "json/alloc.h"
#include "json/stats.h"
#include "module_sim.h"

class MyNewTest : public ::testing::Test {
 protected:
    void SetUp() override {
        JsonUtilCode rc = jsonstats_init();
        ASSERT_EQ(rc, JSONUTIL_SUCCESS);
        setupValkeyModulePointers();
    }
};

TEST_F(MyNewTest, testSomething) {
    // Test DOM operations, selectors, etc.
}
```

Key points:
- Call `jsonstats_init()` in SetUp to initialize the statistics subsystem
- Call `setupValkeyModulePointers()` to wire module API stubs
- Use `SetupAllocFuncs(numShards)` when testing keytable/alloc with shard configuration
- Check `malloced == 0` at end of tests to verify no memory leaks
- Add new `.cc` files to `tst/unit/` - CMake globs all `*.cc` files automatically

## Integration Tests (pytest)

Integration tests run against a real Valkey server with the JSON module loaded. They use the `valkey-test-framework` which provides server lifecycle management.

### Test Framework

| File | Purpose |
|------|---------|
| `json_test_case.py` | `JsonTestCase` base class - starts server with module loaded |
| `test_json_basic.py` | Main test file - all JSON command tests |
| `test_rdb.py` | RDB persistence tests - save/load/migration |
| `utils_json.py` | Constants and helpers - metrics names, paths, size limits |
| `error_handlers.py` | `ErrorStringTester` - error type classification helpers |
| `run.sh` | Test runner - handles ASAN leak checking |
| `data/` | Test data files (wikipedia.json, store.json, etc.) |

### Base Classes

`SimpleTestCase` extends `ValkeyTestCase` from valkey-test-framework:
- Starts a valkey-server instance (local or external)
- Provides `self.server` and `self.client` (valkey-py client)
- Runs `FLUSHALL SYNC` on teardown

`JsonTestCase` extends `SimpleTestCase`:
- Loads the JSON module via `--loadmodule` with `MODULE_PATH`
- Enables debug commands and protected configs
- Provides `verify_error_response()` helper

### Test Data Files

Located in `tst/integration/data/`:

| File | Content |
|------|---------|
| `wikipedia.json` | Large document for performance/stress tests |
| `wikipedia_compact.json` | Compact version of wikipedia document |
| `store.json` | Bookstore data for path query tests |
| `github_events.json` | GitHub API response structure |
| `twitter.json` | Social media data structure |
| `apache_builds.json` | Build system metadata |
| `webxml.json` | XML-to-JSON converted data |
| `truenull.json` | Edge cases with true/null values |

### Running Integration Tests

```bash
# Full integration test suite
./build.sh --integration

# With specific server version
SERVER_VERSION=9.0 ./build.sh --integration

# Run specific test pattern
TEST_PATTERN="test_json_set" ./build.sh --integration

# ASAN integration tests (checks for memory leaks)
ASAN_BUILD=true ./build.sh --integration
```

### Environment Variables for Integration Tests

| Variable | Purpose |
|----------|---------|
| `SERVER_VERSION` | Valkey tag to build and test against |
| `MODULE_PATH` | Path to libjson.so (set automatically by build.sh) |
| `TEST_PATTERN` | pytest -k filter expression |
| `ASAN_BUILD` | Enable ASAN leak detection |
| `VALKEY_EXTERNAL_SERVER` | Set to `true` to use external server |
| `VALKEY_HOST` | External server host (default: localhost) |
| `VALKEY_PORT` | External server port (default: 6379) |

### Python Dependencies

Defined in `requirements.txt`:

```
valkey
pytest==7.4.3
pytest-html
setuptools
```

### Writing Integration Tests

```python
from json_test_case import JsonTestCase

class TestMyFeature(JsonTestCase):
    def test_new_command(self):
        self.client.execute_command('JSON.SET', 'key', '.', '{"a":1}')
        result = self.client.execute_command('JSON.GET', 'key', '.')
        assert result == b'{"a":1}'

    def test_error_case(self):
        self.verify_error_response(
            self.client,
            'JSON.SET key bad_path {}',
            'SYNTAXERR ...'
        )
```

## See Also

- [build.md](build.md) - CMake configuration and build options
- [ci-pipeline.md](ci-pipeline.md) - How tests run in CI
- [adding-commands.md](adding-commands.md) - When tests are needed for new commands
- [jdocument.md](../document/jdocument.md) - JDocument/JValue types tested in dom_test.cc
- [selector.md](../jsonpath/selector.md) - JSONPath selector tested in selector_test.cc
