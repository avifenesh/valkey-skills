# Tcl Integration Tests

Use when you need to run, understand, or write integration tests for Valkey. These tests exercise end-to-end functionality by starting real server instances and sending commands. Build the server first - see [Building Valkey](../build/building.md).

## Contents

- Quick Reference (line 18)
- Running Tests (line 26)
- Test Directory Structure (line 102)
- Tags System (line 145)
- Test Framework API (line 197)
- Writing a New Test (line 278)
- Test Framework Internals (line 313)
- See Also (line 323)

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

## Test Framework API

### Server Management

```tcl
# Start a server and run tests in its context
start_server {tags {"myfeature"}} {
    # r sends commands to the server
    r set mykey myvalue
    r get mykey
}

# Nested servers (for replication tests)
start_server {tags {"replication"}} {
    start_server {} {
        # srv 0 = inner server, srv -1 = outer server
        set master_host [srv -1 host]
        set master_port [srv -1 port]
    }
}

# Access server properties
set pid [srv 0 pid]
set port [srv 0 port]
set host [srv 0 host]
set client [srv 0 client]
```

### Command Shortcuts

```tcl
# r - send command to innermost server
r set key value
r get key

# R n - send command to server at index n
R 0 set key value
R 1 get key

# Rn n - get client object for server n
set client [Rn 0]
$client set key value
```

### Assertions

```tcl
assert {[r get key] eq "value"}
assert_equal [r get key] "value"
assert_match "*pattern*" [r get key]
assert_no_match "*bad*" [r get key]
assert_error "*WRONGTYPE*" {r get mylist}
assert_type "string" key
assert_encoding "raw" key
assert_lessthan $val 100
assert_morethan $val 0
assert_range $val 0 100
```

### Waiting and Retrying

```tcl
wait_for_condition 50 100 {
    [r dbsize] == 0
} else {
    fail "Database was not flushed"
}
```

### Running Tests in Solo Mode

Some tests need exclusive server access (no parallel execution):

```tcl
run_solo {test-name} {
    start_server {} {
        # This test runs alone, not in parallel with others
    }
}
```

## Writing a New Test

1. Choose the right directory:
   - `tests/unit/` for command or feature tests
   - `tests/unit/cluster/` for cluster-mode tests (not `tests/cluster/`)
   - `tests/integration/` for replication, AOF, RDB, cross-feature tests
   - `tests/unit/moduleapi/` for module API tests

2. Create a `.tcl` file or add to an existing one:

```tcl
start_server {tags {"myfeature"}} {
    test {MYCOMMAND - basic usage} {
        r mycommand arg1 arg2
        assert_equal [r mycommand arg1] "expected"
    }

    test {MYCOMMAND - error handling} {
        assert_error "*ERR*" {r mycommand badarg}
    }

    test {MYCOMMAND - slow fuzz test} {
        for {set i 0} {$i < 1000} {incr i} {
            r mycommand [randstring 1 100]
        }
    } {} {slow}
}
```

3. Run your test:

```
./runtest --single unit/myfeature --verbose --dump-logs
```

## Test Framework Internals

The test framework uses a server-client architecture. One server process manages N client processes (default 16). Each client runs test files in parallel. The server assigns test units to idle clients and collects results.

Key settings:
- Default base port: 21111
- Port range: 8000 ports
- Default timeout: 1200 seconds (20 minutes)
- Default parallelism: 16 clients

## See Also

- [Building Valkey](../build/building.md) - build prerequisites and test-related make targets (`make test`, `make test-modules`)
- [C++ Unit Tests](unit-tests.md) - low-level Google Test unit tests for data structures and internals
- [Sanitizer Builds](../build/sanitizers.md) - running integration tests under ASan, UBSan, or Valgrind
- [CI Pipeline](ci-pipeline.md) - which test suites CI runs on every PR and on the daily schedule
- [Contribution Workflow](../contributing/workflow.md) - end-to-end contributor guide including testing requirements
- [Module API Tests](../modules/api-overview.md) - `./runtest-moduleapi` exercises the module API by compiling test modules from `tests/modules/` and running the `tests/unit/moduleapi/` test suite. Module tests validate custom types, blocking commands, and scripting engine integration.
