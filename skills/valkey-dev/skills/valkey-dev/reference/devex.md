# Developer Experience: Build, Test, Config-System

Build, test, and config-system invariants for writing valkey server code.

## Critical correctness rules

- Reply ordering: `lookupKey*` and type-check must run BEFORE `addReplyArrayLen` / `addReplyMapLen` / `addReplyPushLen`. Emitting the header then an error desyncs RESP for every subsequent reply on the connection. Canonical bug class.
- `src/commands/*.json` edits require `make commands.def` and committing the regenerated file. CI fails on diff. `lastkey` is an argv position; miscounting breaks cluster routing with CROSSSLOT.
- Module-API struct changes use `VersionN` extension, never in-place mutation. Bump `VALKEYMODULE_*_ABI_VERSION`, keep V1, add V2 that embeds V1, version-gate reads with `methods.version >= N`. A mutation silently breaks every compiled out-of-tree module.
- Reply schema is CI-enforced; reply-schema-validator runs in Daily. Array replies: scalar-per-entry fields are singular (`shard`, not `shards`).
- `server.current_client` may be NULL. Active expire, `delKeysInSlot`, module cron, module timer, cluster topology updates synthesize writes with no current client. Null-guard or resolve via `server.executing_client`.

## Code rules

- `clang-format-18` is the exact version. CI enforces (config: `src/.clang-format`).
- No doxygen syntax (`///`, `/** @param */`). Project doesn't use doxygen.
- `UNUSED(x)` over `(void)x`.
- `size_t` for sizes, even when `uint32_t` fits.
- `_Static_assert` over runtime asserts for compile-time invariants.
- No `inline` in `.c` when the function is called across TUs - move to header or drop `inline`.
- `deps/` is vendored (jemalloc, libvalkey, lua, hiredis fork). Upstream-first, version-bump here.
- DCO sign-off on every commit (`git commit -s`). CI blocks without it.
- Don't stage runtime artifacts: `dump.rdb`, `nodes.conf`, `*.log`, ad-hoc cluster dirs.

## Test rules

- `wait_for_condition 1000 50` over hardcoded sleeps. Bare `after N` without a source-rooted constant is rejected.
- Pipelined deferring clients: use `CLIENT REPLY OFF` to avoid TCP-backpressure flakes.
- `DEBUG SET-ACTIVE-EXPIRE 0` must precede `debug loadaof` for TTL-bearing values - otherwise active expire races the load.
- Cluster tests use hash-tag keys `{t}key1 {t}key2` for multi-key operations. `{} {cluster:skip}` fallback for standalone-only tests.
- Primary/replica SCAN comparisons alternate cursors; SCAN is not consistent across RDB dump/load or across primary/replica (independent hash seeds).
- Test tags: `slow`, `valgrind:skip`, `tls:skip`, `external:skip`, `needs:debug`, `logreqres:skip`. `--tags network` does NOT include cluster tests. Long cluster tests: `tags {"slow valgrind:skip"}`; ASAN+cluster OOMs runners, `run_solo` for heavy suites.
- Latency-sensitive tests use `CLOCK_THREAD_CPUTIME_ID` / `CLOCK_PROCESS_CPUTIME_ID`, not wall-clock. `assert_range` with wide windows, not tight equality.
- Under ASAN: parametrize memory-heavy tests down (16 GB runners); gate with `#ifdef __SANITIZE_ADDRESS__`. `RTLD_DEEPBIND` is ASAN-incompatible.
- Use `assert_morethan`, `assert_encoding`, `assert_equal`, `assert_match` - not raw `assert {...}`. `assert_match` is glob.

## Sanitizer builds

| Sanitizer | Makefile forces `MALLOC=` |
|-----------|---------------------------|
| `address` | `libc` |
| `undefined` | `libc` |
| `thread` | (no override - jemalloc stays) |

- `make distclean` between sanitizer modes - objects compiled against jemalloc can't re-link when `MALLOC=libc` kicks in.
- `check_sanitizer_errors` (`tests/support/server.tcl`) runs after every server stop; matches `Sanitizer` OR `runtime error` on stderr (GCC UBSAN uses the second form). Update `util.tcl` filter for legitimate suppressions.

## Config system

New config: add a `standardConfig` registration entry in `src/config.c`. Flags available: `IMMUTABLE_CONFIG`, `PROTECTED_CONFIG` (gated on `enable-protected-configs`), `HIDDEN_CONFIG`, `SENSITIVE_CONFIG`, `DEBUG_CONFIG`, `DENY_LOADING_CONFIG`.

Renamed configs - grepping the Redis name finds only the alias:

| Primary (Valkey) | Legacy alias |
|------------------|--------------|
| `replicaof` | `slaveof` |
| `replica-priority` | `slave-priority` |
| `primaryuser` | `masteruser` |
| `primaryauth` | `masterauth` |

Many other `slave-*` -> `replica-*` renames follow the same pattern.
