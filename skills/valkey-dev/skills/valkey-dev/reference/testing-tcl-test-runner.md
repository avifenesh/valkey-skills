# Tcl Test Runner

Use when you need to run integration tests, understand the test directory layout, or filter tests using tags.

Entry points: `./runtest` (core), `./runtest-cluster` (legacy cluster), `./runtest-moduleapi` (module API), `./runtest-sentinel` (sentinel). Common options: `--single unit/file`, `--only "name"`, `--tags -slow`, `--verbose`, `--dump-logs`, `--tls`, `--io-threads`, `--valgrind`, `--loop`, `--accurate`, `--clients N`.

Tags: set on `start_server` blocks or individual tests. `slow` (skip in PR CI), `needs:debug`, `needs:other-server`, `large-memory`. Exclude with `-tag`, include with `tag`.

Source: `tests/test_helper.tcl`
