# Sanitizer Builds

Use when you need to detect memory errors, undefined behavior, or data races during development or test runs. For basic build setup, see [Building Valkey](building.md) first.

## Contents

- Supported Sanitizers (line 19)
- Building with Sanitizers (line 29)
- Running Tests Under Sanitizers (line 75)
- Valgrind (line 92)
- Suppressions File (line 140)
- CI Sanitizer Configuration (line 148)
- Common Issues Caught (line 170)
- Tips (line 191)

---

## Supported Sanitizers

Valkey supports three sanitizers via the `SANITIZER` Makefile variable:

| Value | Sanitizer | Detects |
|-------|-----------|---------|
| `address` | AddressSanitizer (ASan) | Buffer overflows, use-after-free, memory leaks, stack overflow |
| `undefined` | UndefinedBehaviorSanitizer (UBSan) | Signed integer overflow, null dereference, misaligned access, shift errors |
| `thread` | ThreadSanitizer (TSan) | Data races, lock order inversions |

## Building with Sanitizers

### AddressSanitizer

```
make SANITIZER=address
```

This automatically:
- Switches to `MALLOC=libc` (ASan is incompatible with jemalloc)
- Adds `-fsanitize=address -fno-sanitize-recover=all -fno-omit-frame-pointer` to CFLAGS
- Adds `-fsanitize=address` to LDFLAGS

### UndefinedBehaviorSanitizer

```
make SANITIZER=undefined
```

This automatically:
- Switches to `MALLOC=libc`
- Adds `-fsanitize=undefined -fno-sanitize-recover=all -fno-omit-frame-pointer` to CFLAGS
- Adds `-fsanitize=undefined` to LDFLAGS

### ThreadSanitizer

```
make SANITIZER=thread
```

This adds `-fsanitize=thread -fno-sanitize-recover=all -fno-omit-frame-pointer` flags but does not force `MALLOC=libc` - TSan can work with jemalloc.

### Combined with Other Options

For CI-quality builds, combine sanitizer with optimization and warnings:

```
# ASan with O3 optimization (as used in CI)
make all-with-unit-tests OPT=-O3 SANITIZER=address SERVER_CFLAGS='-Werror'

# UBSan with O3
make all-with-unit-tests OPT=-O3 SANITIZER=undefined SERVER_CFLAGS='-Werror'
```

Always run `make distclean` before switching sanitizer modes. The build system persists settings and detects changes, but a clean rebuild avoids stale objects.

## Running Tests Under Sanitizers

Build with sanitizer, then run tests normally:

```
make SANITIZER=address
./runtest --verbose --dump-logs
./runtest-moduleapi --verbose --dump-logs
./runtest-sentinel
./runtest-cluster
make test-unit
```

The test framework (`tests/support/server.tcl`) has built-in sanitizer error detection. After each test server shuts down, it calls `check_sanitizer_errors` which parses stderr for sanitizer reports. Sanitizer errors are reported as test failures.

The sanitizer detection in `tests/support/util.tcl` (`sanitizer_errors_from_file`) ignores `WARNING: AddressSanitizer failed to allocate` messages (huge allocation warnings) to reduce false positives.

## Valgrind

Valgrind is an alternative to ASan for memory checking. It requires a special build:

```
make valgrind
```

This builds with `-O0` and `MALLOC=libc`. Run tests under Valgrind:

```
./runtest --valgrind --no-latency --verbose --clients 1 --timeout 2400 --dump-logs
```

Key Valgrind flags used in CI:

```
--track-origins=yes
--suppressions=./src/valgrind.sup
--show-reachable=no
--show-possibly-lost=no
--leak-check=full
```

For unit tests under Valgrind:

```
# Using gtest-parallel wrapper
./deps/gtest-parallel/gtest-parallel valgrind -- \
    --track-origins=yes \
    --suppressions=./src/valgrind.sup \
    --show-reachable=no \
    --show-possibly-lost=no \
    --leak-check=full \
    --log-file=err.%p.txt \
    ./src/unit/valkey-unit-gtests --valgrind
```

### Helgrind

For thread-safety analysis with Valgrind's Helgrind tool:

```
make helgrind
```

This builds with `-O0`, `MALLOC=libc`, and `-D__ATOMIC_VAR_FORCE_SYNC_MACROS` to make atomics visible to Helgrind.

## Suppressions File

`src/valgrind.sup` contains known false positives:

- `lzf_compress` - uninitialized value checks (Cond, Value4, Value8) in the hash table
- `ztrymalloc_usable` - negative size allocation triggered by corrupt-dump tests
- `allocBioJob` - background I/O jobs in flight at exit

## CI Sanitizer Configuration

The sanitizer CI jobs are defined in `.github/workflows/daily.yml` and `.github/workflows/ci.yml`. See [CI Pipeline](../testing/ci-pipeline.md) for the full workflow reference.

### On Every PR (ci.yml)

- **test-sanitizer-address**: ASan build with `BUILD_TLS=module`, runs integration tests and unit tests. Single compiler.

### Daily / Release Branch PRs (daily.yml)

- **test-sanitizer-address**: ASan with O3, matrix over `[gcc, clang]`. Runs all test suites.
- **test-sanitizer-address-large-memory**: ASan with large-memory unit tests. Monitors memory usage (needs 10-14 GB due to ASan overhead; runners provide 16 GB).
- **test-sanitizer-undefined**: UBSan with O3, matrix over `[gcc, clang]`. Full test suite.
- **test-sanitizer-undefined-large-memory**: UBSan with large-memory unit tests.
- **test-sanitizer-force-defrag**: ASan with `DEBUG_FORCE_DEFRAG=yes`, tests defragmentation without jemalloc.
- **test-valgrind-test**: Valgrind run on integration tests.
- **test-valgrind-misc**: Valgrind run on module API tests and unit tests.
- **test-valgrind-no-malloc-usable-size-test**: Valgrind with `NO_MALLOC_USABLE_SIZE`.
- **test-valgrind-no-malloc-usable-size-misc**: Same, for modules and unit tests.

All sanitizer/valgrind daily jobs have a 24-hour timeout (`timeout-minutes: 1440`).

## Common Issues Caught

### AddressSanitizer

- Buffer overflows in string manipulation (SDS operations)
- Use-after-free when objects are freed during iteration
- Stack buffer overflows in command parsing
- Memory leaks in error paths

### UndefinedBehaviorSanitizer

- Signed integer overflow in hash calculations
- Misaligned memory access on struct fields
- Shift operations exceeding type width
- Null pointer dereference in edge cases

### ThreadSanitizer

- Races between I/O threads and main thread
- Unsynchronized access to shared state during background operations

## Tips

- ASan and UBSan increase memory usage 2-3x. Large-memory tests need 10-14 GB with sanitizers.
- Valgrind is 10-20x slower than native execution. Use `--clients 1` and increase `--timeout`.
- When a sanitizer catches something, the error is printed to stderr with a stack trace. The test framework captures this and reports it as a test error.
- Use `make distclean` between different sanitizer builds.
- For local development, ASan is the most useful sanitizer to run regularly.
