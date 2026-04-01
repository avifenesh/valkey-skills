# Tcl Test Framework API

Use when writing new integration tests for Valkey, using the test assertion API, managing server instances in tests, or understanding the test framework internals.

## Contents

- Server Management (line 14)
- Command Shortcuts (line 41)
- Assertions (line 56)
- Waiting and Retrying (line 73)
- Running Tests in Solo Mode (line 82)
- Writing a New Test (line 91)
- Test Framework Internals (line 129)
- See Also (line 139)

---

## Server Management

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

## Command Shortcuts

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

## Assertions

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

## Waiting and Retrying

```tcl
wait_for_condition 50 100 {
    [r dbsize] == 0
} else {
    fail "Database was not flushed"
}
```

## Running Tests in Solo Mode

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

---

## See Also

- [tcl-test-runner](tcl-test-runner.md) - running tests, directory structure, tags system
- [unit-tests](unit-tests.md) - Google Test C++ unit tests
- [ci-pipeline](ci-pipeline.md) - CI pipeline configuration
