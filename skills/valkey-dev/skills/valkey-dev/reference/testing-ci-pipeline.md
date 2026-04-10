# CI Pipeline

Use when you need to understand what CI checks run on your PR or diagnose CI failures.

CI config in `.github/workflows/`. PR gate: `ci.yml` - builds with `-Werror`, runs integration tests (skip slow), module API tests, unit tests, validates `commands.def`. Also runs ASan, TLS, RDMA, 32-bit, macOS, clang-format, and compatibility checks.

Daily extended tests (`daily.yml`): Valgrind, UBSan, ARM, FreeBSD, Alpine, I/O threads, RPM distros, reply schemas. Required for release branch PRs; informational for `unstable` (add `run-extra-tests` label).

Key commands: `make -j4 all-with-unit-tests SERVER_CFLAGS='-Werror' BUILD_TLS=yes USE_LIBBACKTRACE=yes`, `./runtest --verbose --tags -slow --dump-logs`, `make test-unit`.

Common failures: clang-format diff (run `clang-format-18 -i`), commands.def stale (run `make commands.def`), ASan errors (check stack trace).

Source: `.github/workflows/ci.yml`, `.github/workflows/daily.yml`
