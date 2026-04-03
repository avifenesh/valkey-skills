# Event Loop Architecture

Use when you need to understand how Valkey multiplexes I/O, processes timers, or hooks into the event cycle.

Standard ae reactor pattern (same as Redis). Valkey-specific additions:

- `poll_mutex` in `aeEventLoop` and `AE_PROTECT_POLL` flag protect poll operations for I/O thread safety
- `custompoll` callback allows I/O threads to use a custom poll function
- `afterSleep` hook calls `adjustIOThreadsByEventLoad()` - dynamically scales active I/O threads based on event volume (Valkey 8.0+)
- `beforeSleep` coordinates I/O thread read/write completions and sends poll jobs to I/O threads
- Time events use `monotime` (hardware TSC when available) instead of gettimeofday

Source: `src/ae.c`, `src/ae.h` (~570 lines). Backend files: `ae_epoll.c`, `ae_kqueue.c`, `ae_evport.c`, `ae_select.c`.
