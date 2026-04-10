# Scripting Engine Architecture

Use when investigating the pluggable scripting engine framework, the engine ABI, or key data structures.

Valkey-specific subsystem (Redis has only hardcoded Lua). Defines an `engineMethods` interface that any module can implement, enabling new scripting languages without modifying the server core. The Lua engine itself registers through this interface.

## Key Structures

- **`scriptingEngine`**: Name, module reference, callbacks + opaque context, 3-element module context cache.
- **`engineManager`**: Singleton dict of all engines (case-insensitive) + total memory overhead.
- **`compiledFunction`**: Engine-produced artifact - name, opaque compiled code, description, flags, ABI version.

## Engine ABI

4 versions. Current: `VALKEYMODULE_SCRIPTING_ENGINE_ABI_VERSION = 4`. V1: initial. V2: binary-safe `compile_code`. V3: `reset_env` with subsystem type. V4: debugger callbacks. Core callbacks: `compile_code`, `free_function`, `call_function`, `get_function_memory_overhead`, `reset_env`, `get_memory_info`. Two subsystems: `VMSE_EVAL` (ad-hoc scripts) and `VMSE_FUNCTION` (libraries).

Source: `src/scripting_engine.c`, `src/scripting_engine.h`
