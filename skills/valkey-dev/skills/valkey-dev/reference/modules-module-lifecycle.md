# Module Lifecycle and Command Registration

Use when building a Valkey module from scratch, understanding load/unload, or registering commands.

Standard module lifecycle - `.so` loaded via `dlopen`, entry point `ValkeyModule_OnLoad` (or legacy `RedisModule_OnLoad`), `ValkeyModule_Init()` required first, commands registered with `ValkeyModule_CreateCommand()`. Subcommands via `ValkeyModule_CreateSubcommand()`. Context object provides flags, client info, auto-memory, pool allocator.

Source: `src/valkeymodule.h`, `src/module.c`
