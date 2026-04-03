# Debug Facilities

Use when investigating server crashes, inspecting internal data structures, or using the DEBUG command.

Standard DEBUG command with object introspection, crash simulation, persistence testing, and diagnostic subcommands. Crash reporting via `sigsegvHandler()` with multi-thread stack trace collection, CPU register dump, and fast memory test. Software watchdog via SIGALRM with configurable period.

Source: `src/debug.c`
