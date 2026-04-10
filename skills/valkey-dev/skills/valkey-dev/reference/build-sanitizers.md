# Sanitizer Builds

Use when you need to detect memory errors, undefined behavior, or data races during development or test runs.

Standard ASan/UBSan/TSan usage via `make SANITIZER=address|undefined|thread`. No Valkey-specific sanitizer changes.

Key points: ASan forces `MALLOC=libc`. TSan can use jemalloc. Run `make distclean` between sanitizer mode switches. The test framework (`tests/support/server.tcl`) auto-detects sanitizer errors in stderr after each test server shutdown.
