# Module Patterns and Utilities

Use when looking up module error handling, memory management, API versioning, or reply helpers.

Standard module patterns - `VALKEYMODULE_OK`/`VALKEYMODULE_ERR` return codes, auto-memory mode, pool allocator, tracked allocator (routes through zmalloc). `redismodule.h` compatibility header maps all `RedisModule_*` functions to `ValkeyModule_*` equivalents (Redis 7.2.4 snapshot). Reply helpers for all RESP types.

Source: `src/valkeymodule.h`, `src/module.c`
