# Testing Modules

Use when writing tests for a custom module, setting up CI for module builds, loading/unloading modules at runtime, or debugging module issues.

Source: `tests/unit/moduleapi/`, `tests/modules/`, `tests/support/`

## Contents

- Test Infrastructure (line 18)
- Writing Tcl Tests for Your Module (line 38)
- Building Test Modules (line 127)
- CI Integration (line 161)
- Loading and Unloading at Runtime (line 173)
- Debugging Tips (line 179)

---

## Test Infrastructure

Valkey provides a dedicated test runner for modules:

```bash
./runtest-moduleapi --verbose
```

This builds all test modules in `tests/modules/` automatically, then runs tests in `tests/unit/moduleapi/`. It uses the same Tcl harness as core tests.

### Running specific module tests

```bash
./runtest-moduleapi --single tests/unit/moduleapi/auth
./runtest-moduleapi --single tests/unit/moduleapi/blockedclient
./runtest-moduleapi --only "Module command filter"
```

---

## Writing Tcl Tests for Your Module

### Test file structure

Create a `.tcl` file in `tests/unit/moduleapi/` (for in-tree modules) or in your own test directory:

```tcl
set testmodule [file normalize tests/modules/mymodule.so]

start_server {tags {"modules"}} {
    r module load $testmodule

    test "MYMOD.SET stores a value" {
        r mymod.set mykey myvalue
        assert_equal [r mymod.get mykey] "myvalue"
    }

    test "MYMOD.SET overwrites existing" {
        r mymod.set mykey newvalue
        assert_equal [r mymod.get mykey] "newvalue"
    }

    test "MYMOD.GET returns nil for missing key" {
        assert_equal [r mymod.get nokey] {}
    }
}
```

### Key test helpers

| Helper | Purpose |
|--------|---------|
| `r <cmd>` | Send command to the Valkey server |
| `assert_equal <a> <b>` | Assert values are equal |
| `assert_error <pattern> <cmd>` | Assert command returns an error matching pattern |
| `assert_match <glob> <str>` | Glob pattern match |
| `wait_for_condition <ms> <interval> <expr>` | Poll until expression is true |
| `catch {<cmd>} err` | Capture error into `$err` |
| `wait_for_blocked_client` | Wait until a client is blocked |

### Testing persistence (RDB/AOF)

```tcl
test "MYMOD type survives restart" {
    r mymod.set mykey 42
    r debug reload                ;# save + quit + restart + load
    assert_equal [r mymod.get mykey] "42"
}

test "MYMOD type survives AOF rewrite" {
    r config set appendonly yes
    r mymod.set mykey 100
    r bgrewriteaof
    waitForBgrewriteaof r
    r debug loadaof
    assert_equal [r mymod.get mykey] "100"
}
```

### Testing blocking commands

```tcl
test "MYMOD.BGET blocks until key is ready" {
    set rd [valkey_deferring_client]
    $rd mymod.bget mykey 5000      ;# 5s timeout
    wait_for_blocked_client

    r mymod.set mykey "hello"      ;# signal the key
    assert_equal [$rd read] "hello"
    $rd close
}
```

### Testing module load/unload

```tcl
test "Module loads with arguments" {
    r module load $testmodule arg1 arg2
    assert_match {*mymodule*} [r module list]
}

test "Module unloads cleanly" {
    r module unload mymodule
    assert_error {*ERR*} {r mymod.set x y}
}
```

---

## Building Test Modules

### In-tree (contributing to Valkey)

Place your `.c` file in `tests/modules/`. The Makefile at `tests/modules/Makefile` compiles all `.c` files to `.so` automatically when `runtest-moduleapi` runs.

### Out-of-tree (your own module)

Create a Makefile:

```makefile
VALKEY_SRC ?= /path/to/valkey/src

CFLAGS = -Wall -g -fPIC -std=gnu11 -I$(VALKEY_SRC)
LDFLAGS = -shared

.PHONY: all clean test

all: mymodule.so

mymodule.so: mymodule.c
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $<

clean:
	rm -f mymodule.so

test: mymodule.so
	cd $(VALKEY_SRC)/.. && ./runtest --single $(PWD)/tests/mymodule
```

You only need the `valkeymodule.h` header - no linking to the Valkey server binary.

---

## CI Integration

### GitHub Actions pattern

Clone and build Valkey (`git clone --depth 1 valkey-io/valkey && cd valkey && make -j$(nproc)`), build your module (`make VALKEY_SRC=valkey/src`), start the server with `--loadmodule ./mymodule.so --daemonize yes`, run tests, then `SHUTDOWN NOSAVE`.

### Sanitizers and Valgrind

Build Valkey with `make SANITIZER=address` (ASan) or `make SANITIZER=undefined` (UBSan) to catch memory issues in your module. Run module tests under Valgrind: `./runtest-moduleapi --valgrind --no-latency --clients 1 --timeout 2400`.

---

## Loading and Unloading at Runtime

Startup: `loadmodule /path/to/mymodule.so [args]` in `valkey.conf`. Runtime (requires `enable-module-command yes`): `MODULE LOAD /path/to/mymodule.so [args]`. List: `MODULE LIST`. Unload: `MODULE UNLOAD mymodule` - calls `OnUnload` if defined, fails if custom-type keys exist or module configs were modified.

---

## Debugging Tips

**Crash in module**: Build Valkey with `make noopt` for full debug symbols. Run under gdb: `gdb --args ./valkey-server --loadmodule ./mymodule.so`.

**Memory leaks**: Use `ValkeyModule_Alloc`/`Free` (not raw malloc) so leaks appear in `INFO memory`. Run with ASan for precise tracking.

**RDB corruption**: Test `rdb_load`/`rdb_save` round-trip with `DEBUG RELOAD`. Check `ValkeyModule_IsIOError` after every load call.

**Log from callbacks**: Use `ValkeyModule_Log(ctx, "warning", "debug: %s", msg)` - output appears in the server log.

**Check API availability**: Use `RMAPI_FUNC_SUPPORTED(ValkeyModule_SomeFunc)` before calling APIs that may not exist on older Valkey versions.
