# C++ Unit Tests

Use when you need to run, understand, or write unit tests for Valkey's data structures and internal functions.

Google Test (gtest) + Google Mock (gmock) in `src/unit/`. Binary: `valkey-unit-gtests`. Build with `make all-with-unit-tests`, run with `make test-unit` (uses `gtest-parallel`). Filter: `--gtest_filter="SdsTest.*"`. Custom flags: `--accurate`, `--large-memory`, `--seed N`.

Tests cover: SDS, dict, hashtable, intset, listpack, quicklist, rax, kvstore, bitops, CRC, SHA, zmalloc, networking, object, entry, vector. Write new tests in `src/unit/test_mymodule.cpp`, wrap C headers in `extern "C"`, use function mocking via `wrappers.h`.

Source: `src/unit/`, `src/unit/Makefile`
