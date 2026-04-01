# Tcl Test Runner

Use when you need to run integration tests for Valkey, understand the test directory layout, or filter tests using the tags system. Build the server first - see [Building Valkey](../build/building.md).

## Contents

- Quick Reference (line 16)
- Running Tests (line 24)
- Test Directory Structure (line 100)
- Tags System (line 143)
- See Also (line 194)

---

## Quick Reference

    ./runtest --verbose                           # Run all integration tests
    ./runtest --single tests/unit/expire          # Run one test file
    ./runtest --single tests/unit/expire --only "volatile*"  # Run matching tests
    ./runtest --verbose --tags "-slow"            # Skip slow tests
    ./runtest-moduleapi --verbose                 # Run module API tests

## Running Tests

### Entry Points

Four shell scripts in the repo root launch different test suites:

| Script | What it runs | Description |
|--------|-------------|-------------|
| `./runtest` | `tests/test_helper.tcl` | Core integration tests (unit/, integration/) |
| `./runtest-cluster` | `tests/cluster/run.tcl` | Legacy cluster tests (deprecated for new tests) |
| `./runtest-moduleapi` | `tests/test_helper.tcl --moduleapi` | Module API tests, builds test modules first |
| `./runtest-sentinel` | `tests/sentinel/run.tcl` | Sentinel-specific tests |

All scripts locate tclsh (8.5, 8.6, or 9.0) automatically.

### Common Options

```
# Run all tests, show details, dump logs on failure
./runtest --verbose --dump-logs

# Skip slow tests (used in PR CI)
./runtest --verbose --tags -slow --dump-logs

# Run a single test file
./runtest --single unit/bitops

# Run a single test file from a subdirectory
./runtest --single unit/cluster/slot-migration

# Run specific test by name
./runtest --only "BITCOUNT returns 0 against non existing key"

# Run specific test by regex
./runtest --only "/BITCOUNT.*"

# Run with more iterations for fuzz tests
./runtest --accurate

# Run under Valgrind
./runtest --valgrind --no-latency --clients 1 --timeout 2400

# Run with TLS enabled
./runtest --tls --dump-logs

# Run with TLS module
./runtest --tls-module --dump-logs

# Run with I/O threads
./runtest --io-threads

# Parallel clients (default 16)
./runtest --clients 8

# Loop forever (useful for flaky test investigation)
./runtest --single unit/bitops --loop

# Loop a fixed number of times
./runtest --single unit/bitops --loops 10

# List all available test units
./runtest --list-tests

# Stop on first failure (interactive debugging)
./runtest --stop

# Exit immediately on first failure
./runtest --fastfail

# Test against an external server
./runtest --host 127.0.0.1 --port 6379

# Run with module API test suite
./runtest-moduleapi --verbose --dump-logs
```

## Test Directory Structure

```
tests/
  test_helper.tcl          # Main test framework entry point
  support/
    valkey.tcl             # Client library for test framework
    server.tcl             # Server lifecycle management
    test.tcl               # Test assertion primitives
    util.tcl               # Utility functions (random strings, crash log parsing)
    cluster_util.tcl       # Cluster test helpers
    tmpfile.tcl            # Temp file management
    aofmanifest.tcl        # AOF manifest helpers
    cli.tcl                # CLI test helpers
    benchmark.tcl          # Benchmark helpers
    cluster.tcl            # Cluster topology helpers
    response_transformers.tcl  # Response format helpers
    set_executable_path.tcl    # Binary path resolution
  unit/                    # Core command and feature tests
    bitops.tcl
    acl.tcl
    expire.tcl
    networking.tcl
    scripting.tcl
    ...
    type/                  # Data type specific tests
    cluster/               # Cluster mode tests (preferred over tests/cluster/)
    moduleapi/             # Module API tests
  integration/             # Cross-feature and replication tests
    aof.tcl
    replication.tcl
    failover.tcl
    rdb.tcl
    ...
  sentinel/                # Sentinel test suite
    run.tcl
    ...
  cluster/                 # Legacy cluster tests (deprecated)
    run.tcl
    ...
  modules/                 # C test modules (compiled by runtest-moduleapi)
```

## Tags System

Tests are organized with tags that control which tests run. Tags are set on server blocks.

### Tag Syntax in Test Files

```tcl
start_server {tags {"bitops"}} {
    test {BITCOUNT against wrong type} {
        # test body
    }
}
```

Individual tests can also have tags:

```tcl
test {some test name} {
    # test body
} {} {needs:debug}
```

### Using Tags from Command Line

```
# Run only tests tagged "slow"
./runtest --tags slow

# Exclude tests tagged "slow"
./runtest --tags -slow

# Combine: run network tests, exclude slow
./runtest --tags "network -slow"
```

### Top-Level-Only Tags

Some tags can only be used in allow-lists (not within test files for filtering):

- `large-memory` - tests requiring significant RAM
- `needs:other-server` - tests requiring a second server binary
- `compatible-redis` - backward compatibility tests
- `network` - tests requiring network features

### Common Tags

- `slow` - long-running tests, excluded from PR CI
- `needs:debug` - requires DEBUG commands
- `needs:other-server` - cross-version compatibility tests
- `singledb` - test uses only DB 0
- `large-memory` - requires substantial RAM

---

## See Also

- [tcl-test-api](tcl-test-api.md) - framework API, assertions, writing new tests
- [unit-tests](unit-tests.md) - Google Test C++ unit tests
- [ci-pipeline](ci-pipeline.md) - CI pipeline configuration
