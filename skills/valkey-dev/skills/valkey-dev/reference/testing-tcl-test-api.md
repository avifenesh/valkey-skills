# Tcl Test Framework API

Use when writing new integration tests for Valkey or using the test assertion API.

Standard Tcl test framework. `start_server {tags {"feature"}} { ... }` to start a server context. `r` sends commands to innermost server. `assert_equal`, `assert_error`, `assert_match`, `assert_type`, `assert_encoding`, `assert_range`. `wait_for_condition 50 100 { expr } else { fail "msg" }` for async checks. `run_solo` for exclusive server access.

New tests go in `tests/unit/` (commands), `tests/unit/cluster/` (cluster), `tests/integration/` (replication/persistence), `tests/unit/moduleapi/` (module API). Run with `./runtest --single unit/myfeature --verbose --dump-logs`.

Source: `tests/support/test.tcl`, `tests/support/server.tcl`
