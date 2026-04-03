# zmalloc - Memory Allocator Wrapper

Use when you need to understand how Valkey tracks memory usage or wraps the underlying allocator.

Standard zmalloc layer wrapping jemalloc/tcmalloc/libc with memory tracking. Provides `zmalloc`, `zcalloc`, `zrealloc`, `zfree` (renamed to `valkey_malloc` etc. to avoid zlib collisions). Reports `used_memory` via `zmalloc_used_memory()`.

Source: `src/zmalloc.c`, `src/zmalloc.h`
