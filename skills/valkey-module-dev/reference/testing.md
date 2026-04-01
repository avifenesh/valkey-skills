# Testing Modules - Valkey Test Framework

Use when writing tests for a custom module, setting up CI for module builds, adding a test module to the Valkey tree, or debugging module issues with the Tcl harness.

Source: `tests/modules/`, `tests/unit/moduleapi/`, `tests/modules/Makefile`, `tests/modules/CMakeLists.txt`

## Contents

- [Test Module Pattern](#test-module-pattern)
- [Tcl Test Harness](#tcl-test-harness)
- [Adding a Module to the Build](#adding-a-module-to-the-build)
- [Running Tests](#running-tests)
- [Test Helpers Reference](#test-helpers-reference)
- [CI Integration](#ci-integration)
- [Debugging Tips](#debugging-tips)

---

## Test Module Pattern

Test modules live in `tests/modules/` as standalone `.c` files. Each file is a self-contained module that registers test commands. The pattern from `tests/modules/basics.c`:

```c
#include "valkeymodule.h"
#include <string.h>
#include <stdlib.h>

/* Command handler that runs test assertions internally */
int TestCall(ValkeyModuleCtx *ctx, ValkeyModuleString **argv, int argc) {
    VALKEYMODULE_NOT_USED(argv);
    VALKEYMODULE_NOT_USED(argc);

    ValkeyModule_AutoMemory(ctx);
    ValkeyModuleCallReply *reply;

    ValkeyModule_Call(ctx, "DEL", "c", "mylist");
    ValkeyModuleString *mystr = ValkeyModule_CreateString(ctx, "foo", 3);
    ValkeyModule_Call(ctx, "RPUSH", "csl", "mylist", mystr, (long long)1234);
    reply = ValkeyModule_Call(ctx, "LRANGE", "ccc", "mylist", "0", "-1");

    if (ValkeyModule_CallReplyLength(reply) != 2) goto fail;

    ValkeyModule_ReplyWithSimpleString(ctx, "OK");
    return VALKEYMODULE_OK;

fail:
    ValkeyModule_ReplyWithSimpleString(ctx, "ERR");
    return VALKEYMODULE_OK;
}

int ValkeyModule_OnLoad(ValkeyModuleCtx *ctx, ValkeyModuleString **argv, int argc) {
    VALKEYMODULE_NOT_USED(argv);
    VALKEYMODULE_NOT_USED(argc);

    if (ValkeyModule_Init(ctx, "test", 1, VALKEYMODULE_APIVER_1) == VALKEYMODULE_ERR)
        return VALKEYMODULE_ERR;

    if (ValkeyModule_CreateCommand(ctx, "test.basics", TestCall,
            "write deny-oom", 1, 1, 1) == VALKEYMODULE_ERR)
        return VALKEYMODULE_ERR;

    return VALKEYMODULE_OK;
}
```

Key conventions:
- Use `VALKEYMODULE_NOT_USED()` to suppress unused parameter warnings
- Include `valkeymodule.h` from the `src/` directory (resolved via `-I../../src` in the Makefile)
- Register commands with a `module.subcommand` naming pattern for test dispatch
- Check API availability with `RMAPI_FUNC_SUPPORTED(ValkeyModule_SomeFunc)` for APIs that may not exist on older versions

---

## Tcl Test Harness

Test files live in `tests/unit/moduleapi/` as `.tcl` files. Each file loads a compiled module and exercises its commands. The pattern from `tests/unit/moduleapi/basics.tcl`:

```tcl
set testmodule [file normalize tests/modules/basics.so]

start_server {tags {"modules"}} {
    r module load $testmodule

    test {test module api basics} {
        r test.basics
    } {ALL TESTS PASSED}

    test "Unload the module - basics" {
        assert_equal {OK} [r module unload test]
    }
}
```

### Structure

1. Set the module path using `file normalize`
2. Wrap tests in `start_server {tags {"modules"}} { ... }` for a fresh instance
3. Load with `r module load $testmodule [args...]`
4. Each `test` block has a name, body, and optional expected result
5. Use `r <command>` to send commands to the server

### Passing arguments to the module

```tcl
set testmodule [file normalize tests/modules/defragtest.so]

start_server {tags {"modules"} overrides {{save ""}}} {
    r module load $testmodule 10000
    r config set active-defrag-ignore-bytes 1
    r config set active-defrag-threshold-lower 0
}
```

The `overrides` modify `valkey.conf` settings. Arguments after the module path are passed to `OnLoad` as `argv`.

### Testing persistence

```tcl
test "Type survives restart" {
    r mymod.set mykey 42
    r debug reload                ;# save + quit + restart + load
    assert_equal [r mymod.get mykey] "42"
}
```

### Testing blocking commands

```tcl
test "Blocking command unblocks on key" {
    set rd [valkey_deferring_client]
    $rd mymod.bget mykey 5000
    wait_for_blocked_client

    r mymod.set mykey "hello"
    assert_equal [$rd read] "hello"
    $rd close
}
```

---

## Adding a Module to the Build

### Makefile (legacy build)

```makefile
TEST_MODULES = \
    commandfilter.so \
    basics.so \
    # ...existing modules...
    mymodule.so
```

The Makefile compiles each `.c` to a `.xo` object, then links to `.so`:

```makefile
%.xo: %.c ../../src/valkeymodule.h
	$(CC) -I../../src $(CFLAGS) $(SHOBJ_CFLAGS) -fPIC -c $< -o $@

%.so: %.xo
	$(LD) -o $@ $^ $(SHOBJ_LDFLAGS) $(LDFLAGS) $(LIBS)
```

### CMakeLists.txt (CMake build)

```cmake
list(APPEND MODULES_LIST "mymodule")
```

The CMake loop handles the rest - it creates a shared library target, sets the include path to `src/`, strips the `lib` prefix, and handles platform-specific link options:

```cmake
foreach (MODULE_NAME ${MODULES_LIST})
    add_library(${MODULE_NAME} SHARED
        "${CMAKE_SOURCE_DIR}/tests/modules/${MODULE_NAME}.c")
    target_include_directories(${MODULE_NAME} PRIVATE "${CMAKE_SOURCE_DIR}/src")
    set_target_properties(${MODULE_NAME} PROPERTIES PREFIX "")
    if (APPLE)
        target_link_options(${MODULE_NAME} PRIVATE -undefined dynamic_lookup)
    endif ()
endforeach ()
```

### Out-of-tree modules

For standalone modules, you only need the `valkeymodule.h` header:

```makefile
VALKEY_SRC ?= /path/to/valkey/src
CFLAGS = -Wall -g -fPIC -std=gnu11 -I$(VALKEY_SRC)
LDFLAGS = -shared

mymodule.so: mymodule.c
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $<
```

No linking to the Valkey binary is required - symbols resolve at load time.

---

## Running Tests

### All module API tests

```bash
./runtest-moduleapi --verbose
```

This builds all test modules automatically, then runs every `.tcl` file in `tests/unit/moduleapi/`.

### Single test file

```bash
./runtest-moduleapi --single tests/unit/moduleapi/basics
```

The `.tcl` extension is optional.

### Specific test by name

```bash
./runtest-moduleapi --only "Module defrag: simple key defrag works"
```

### With Valgrind

```bash
./runtest-moduleapi --valgrind --no-latency --clients 1 --timeout 2400
```

### With sanitizers

Build Valkey with sanitizers first, then run tests normally:

```bash
make SANITIZER=address    # AddressSanitizer
make SANITIZER=undefined  # UBSan
./runtest-moduleapi
```

---

## Test Helpers Reference

| Helper | Purpose |
|--------|---------|
| `r <cmd> [args]` | Send a command to the server |
| `assert_equal <a> <b>` | Assert values are equal |
| `assert_error <pattern> {<cmd>}` | Assert command raises an error matching pattern |
| `assert_match <glob> <str>` | Glob pattern match |
| `wait_for_condition <max_ms> <interval_ms> <expr>` | Poll until expression is true |
| `wait_for_blocked_client` | Wait until a client is blocked |
| `catch {<cmd>} err` | Capture error into `$err` |
| `valkey_deferring_client` | Create async client for blocking tests |
| `start_server {tags overrides} {body}` | Start a fresh server instance |
| `getInfoProperty <info_output> <field>` | Extract a field from INFO output |
| `verify_log_message <idx> <pattern> <offset>` | Check server log for a message |

### Using INFO to verify module state

Modules that register an info callback can be queried:

```tcl
test "Module defrag: global defrag works" {
    after 2000
    set info [r info defragtest_stats]
    assert {[getInfoProperty $info defragtest_global_attempts] > 0}
}
```

---

## CI Integration

Clone and build Valkey (`git clone --depth 1 valkey-io/valkey && cd valkey && make -j$(nproc)`), build your module (`make VALKEY_SRC=valkey/src`), start the server with `--loadmodule ./mymodule.so --daemonize yes`, run tests, then `SHUTDOWN NOSAVE`.

Build with `make SANITIZER=address` (ASan) or `SANITIZER=undefined` (UBSan) to catch memory issues.

---

## Debugging Tips

**Crash in module**: Build with `make noopt` for debug symbols. Run under gdb: `gdb --args ./valkey-server --loadmodule ./mymodule.so`.

**Memory leaks**: Use `ValkeyModule_Alloc`/`Free` (not raw malloc) so leaks appear in `INFO memory`. Run with ASan.

**RDB corruption**: Test `rdb_load`/`rdb_save` round-trip with `DEBUG RELOAD`. Check `ValkeyModule_IsIOError` after every load call.

**Log from callbacks**: `ValkeyModule_Log(ctx, "warning", "debug: %s", msg)` - output appears in the server log.

**API availability**: `RMAPI_FUNC_SUPPORTED(ValkeyModule_SomeFunc)` before calling APIs that may not exist on older versions.

## See Also

- [lifecycle/module-loading.md](lifecycle/module-loading.md) - OnLoad/OnUnload lifecycle
- [commands/registration.md](commands/registration.md) - Command registration for test commands
- [data-types/registration.md](data-types/registration.md) - Data type setup patterns
- [advanced/info-callbacks.md](advanced/info-callbacks.md) - Registering INFO callbacks verified with getInfoProperty in tests
- [defrag.md](defrag.md) - Defrag testing with defragtest.c example
- [rust-sdk.md](rust-sdk.md) - Rust SDK for building modules with cargo test and Tcl harness
