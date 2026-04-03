# EVAL Subsystem

Use when investigating EVAL/EVALSHA command behavior, Lua script caching, script eviction, shebang flag parsing, or the legacy eval-to-engine bridge.

Standard EVAL/EVALSHA subsystem. No Valkey-specific changes to scripting semantics.

Source: `src/eval.c`, `src/script.c`, `src/script.h`. Scripts cached in LRU-bounded dict (500 entries). Shebang flags: `no-writes`, `allow-oom`, `allow-stale`, `no-cluster`, `allow-cross-slot-keys`. Delegates to pluggable scripting engine layer rather than embedding Lua directly.
