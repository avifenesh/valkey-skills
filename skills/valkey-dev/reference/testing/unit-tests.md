# C++ Unit Tests

Use when you need to run, understand, or write low-level unit tests for Valkey's data structures and internal functions. Build the test binary first with `make all-with-unit-tests` - see [Building Valkey](../build/building.md).

---

## Overview

Valkey's unit tests live in `src/unit/` and use Google Test (gtest) with Google Mock (gmock). They test individual C data structures and functions by linking against the Valkey server library (`libvalkey.a`).

The test binary is `valkey-unit-gtests`. It is not built by default - use the `all-with-unit-tests` target.

## Building

```
# Build server plus unit test binary
make all-with-unit-tests

# Dependencies: gtest and gmock must be installed
sudo apt-get install pkg-config libgtest-dev libgmock-dev

# On macOS
brew install googletest
```

The unit test Makefile (`src/unit/Makefile`) auto-detects gtest via pkg-config. To override:

```
make all-with-unit-tests \
    GTEST_CFLAGS="-I/path/to/gtest/include -I/path/to/gmock/include" \
    GTEST_LIBS="/path/to/libgtest.a /path/to/libgmock.a"
```

## Running

```
# Run all unit tests (uses gtest-parallel for speed)
make test-unit

# Run with accurate mode (more iterations for randomized tests)
make test-unit accurate=1

# Run large-memory tests
make test-unit large_memory=1

# Run with a fixed random seed
make test-unit seed=42

# Run under Valgrind
cd src/unit && make valgrind

# Run the binary directly (without gtest-parallel)
./src/unit/valkey-unit-gtests

# Filter tests by name (gtest filter syntax)
./src/unit/valkey-unit-gtests --gtest_filter="SdsTest.*"
./src/unit/valkey-unit-gtests --gtest_filter="DictTest.TestExpand"
```

The `make test-unit` target invokes `gtest-parallel` (`deps/gtest-parallel/gtest_parallel.py`) which runs test cases in parallel across multiple processes for speed.

## Binary Flags

The `main.cpp` entry point accepts custom flags beyond the standard gtest flags:

| Flag | Description |
|------|-------------|
| `--accurate` | Run fuzz tests with more iterations |
| `--large-memory` | Enable tests that require significant RAM |
| `--valgrind` | Set gtest death test style to threadsafe |
| `--seed <value>` | Fixed random seed for reproducibility |

These are parsed by the custom `main()` in `src/unit/main.cpp` before `::testing::InitGoogleMock()` processes standard gtest flags.

## Test Files

Each file tests a specific module or data structure:

| File | What it tests |
|------|---------------|
| `test_sds.cpp` | Simple Dynamic Strings (SDS) |
| `test_dict.cpp` | Dictionary (hash table) |
| `test_hashtable.cpp` | New hash table implementation |
| `test_intset.cpp` | Integer set |
| `test_listpack.cpp` | Listpack encoding |
| `test_quicklist.cpp` | Quicklist (linked list of listpacks) |
| `test_ziplist.cpp` | Ziplist encoding (legacy) |
| `test_zipmap.cpp` | Zipmap encoding (legacy) |
| `test_rax.cpp` | Radix tree |
| `test_kvstore.cpp` | Key-value store layer |
| `test_bitops.cpp` | Bit operations |
| `test_crc64.cpp` | CRC64 implementation |
| `test_crc64combine.cpp` | CRC64 combine operations |
| `test_sha1.cpp` | SHA1 implementation |
| `test_sha256.cpp` | SHA256 implementation |
| `test_endianconv.cpp` | Endian conversion |
| `test_util.cpp` | Utility functions |
| `test_zmalloc.cpp` | Memory allocation wrapper |
| `test_networking.cpp` | Networking internals |
| `test_object.cpp` | Object system |
| `test_fifo.cpp` | FIFO queue |
| `test_mutexqueue.cpp` | Mutex queue |
| `test_entry.cpp` | Entry abstraction |
| `test_vector.cpp` | Vector data structure |
| `test_vset.cpp` | Vector set |
| `test_valkey_strtod.cpp` | String-to-double conversion |
| `example_tests.cpp` | Example/template tests |

## Writing a New Unit Test

### 1. Create the Test File

Create `src/unit/test_mymodule.cpp`:

```cpp
/*
 * Copyright (c) Valkey Contributors
 * All rights reserved.
 * SPDX-License-Identifier: BSD-3-Clause
 */

#include "generated_wrappers.hpp"
#include <cstring>

extern "C" {
#include "myheader.h"
}

class MyModuleTest : public ::testing::Test {};

TEST_F(MyModuleTest, BasicOperation) {
    // Test code using ASSERT_* and EXPECT_* macros
    ASSERT_EQ(myFunction(42), 42);
    EXPECT_TRUE(myPredicate("hello"));
}

TEST_F(MyModuleTest, EdgeCase) {
    ASSERT_NE(myFunction(0), -1);
}
```

### 2. Include Headers

Valkey is written in C, so wrap includes in `extern "C"`:

```cpp
extern "C" {
#include "sds.h"
#include "zmalloc.h"
}
```

### 3. Use Global Flags

Access the global flags set by `main.cpp`:

```cpp
extern bool accurate;
extern bool large_memory;

TEST_F(MyModuleTest, FuzzTest) {
    int iterations = accurate ? 100000 : 1000;
    for (int i = 0; i < iterations; i++) {
        // fuzz test body
    }
}
```

### 4. Use Function Mocking

The test framework generates mock wrappers for C functions listed in `wrappers.h`. On Linux, this uses `--wrap` linker flags. On macOS, it uses symbol redefinition via `llvm-objcopy`.

To mock a function:

1. Declare it in `src/unit/wrappers.h` with the `__wrap_` prefix
2. Run `make` - `generate-wrappers.py` creates `generated_wrappers.cpp` automatically
3. Use gmock's `EXPECT_CALL` and `ON_CALL` in your tests

### 5. Build and Run

```
make all-with-unit-tests
make test-unit
```

Or run just your tests:

```
./src/unit/valkey-unit-gtests --gtest_filter="MyModuleTest.*"
```

## Build System Details

The unit test `Makefile` at `src/unit/Makefile`:

- Compiles all `.cpp` files (except `generated_wrappers.cpp`) as test sources
- Links against `../libvalkey.a` (the server compiled as a static library)
- Links gtest, gmock, and all Valkey dependencies (jemalloc, libvalkey, hdr_histogram, etc.)
- Uses C++17 standard
- Enforces strict warnings with `-Werror` and many `-Werror=*` flags
- Inherits `CFLAGS`, `MALLOC`, `BUILD_TLS`, and `USE_LIBBACKTRACE` from the parent Makefile

## Unit vs Integration Tests

| Aspect | Unit Tests (C++) | Integration Tests (Tcl) |
|--------|-----------------|------------------------|
| Location | `src/unit/` | `tests/` |
| Language | C++ with gtest | Tcl |
| Speed | Fast (seconds) | Slower (minutes) |
| What to test | Data structures, algorithms, internal APIs | Commands, replication, clustering, client protocol |
| Server needed | No (links server as library) | Yes (spawns real server processes) |
| When to use | Changing data structures or internal functions | Adding commands, changing server behavior |

From `DEVELOPMENT_GUIDE.md`: "Most changes to data structures should include corresponding unit tests. Adding new commands should come with corresponding integration tests."

## See Also

- [Building Valkey](../build/building.md) - build prerequisites, `make all-with-unit-tests`, and dependency setup
- [Tcl Integration Tests](tcl-tests.md) - end-to-end integration tests for commands and server behavior
- [Sanitizer Builds](../build/sanitizers.md) - running unit tests under ASan or Valgrind
- [CI Pipeline](ci-pipeline.md) - how unit tests are executed in CI (`make test-unit`)
- [Contribution Workflow](../contributing/workflow.md) - when to write unit tests vs integration tests
- [Module API Overview](../modules/api-overview.md) - module API integration tests are run separately via `./runtest-moduleapi`, not through the unit test binary. Unit tests cover core data structures; module tests are Tcl-based integration tests.
