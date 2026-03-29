# Functions Subsystem

Use when investigating FUNCTION LOAD/CALL/DELETE/LIST/STATS/DUMP/RESTORE, function libraries, the FCALL command, or how functions differ from EVAL scripts.

Source files: `src/functions.c`, `src/functions.h`, `src/script.c`

---

## Overview

The Functions subsystem provides named, persistent, library-based scripting. Unlike EVAL scripts (identified by SHA1 hash, cached transiently), functions are organized into libraries with explicit names, persisted to RDB, and replicated as structured data. A single library can register multiple functions.

## How Functions Differ from EVAL

| Aspect | EVAL | Functions |
|--------|------|-----------|
| Identity | SHA1 hash of script body | Explicit function name |
| Grouping | None - each script stands alone | Library groups multiple functions |
| Persistence | Not persisted (cache only) | Saved in RDB, replicated |
| Eviction | LRU-evicted after 500 entries | Never evicted |
| Loading | Implicit on EVAL, explicit on SCRIPT LOAD | Explicit FUNCTION LOAD |
| Invocation | `EVAL script numkeys ...` | `FCALL funcname numkeys ...` |
| Flags | Optional shebang on script body | Per-function flags set during compilation |
| Subsystem type | `VMSE_EVAL` | `VMSE_FUNCTION` |

## Key Data Structures

### functionsLibCtx

The top-level container for all loaded libraries and functions:

```c
struct functionsLibCtx {
    dict *libraries;     /* Library name (sds) -> functionLibInfo* */
    dict *functions;     /* Function name (sds) -> functionInfo* */
    size_t cache_memory; /* Overhead memory for structs and dicts */
    dict *engines_stats; /* Engine name (sds) -> functionsLibEngineStats* */
};
```

A global `curr_functions_lib_ctx` pointer holds the active context. This is swapped atomically during FUNCTION RESTORE with FLUSH policy.

### functionLibInfo

Represents one loaded library:

```c
struct functionLibInfo {
    sds name;                /* Library name */
    dict *functions;         /* Function name (sds) -> functionInfo* */
    scriptingEngine *engine; /* Engine that compiled this library */
    sds code;                /* Full library source code */
};
```

### functionInfo

Represents one function within a library:

```c
typedef struct functionInfo {
    compiledFunction *compiled_function; /* Engine-compiled function */
    functionLibInfo *li;                 /* Back-pointer to owning library */
} functionInfo;
```

### functionsLibEngineStats

Per-engine statistics:

```c
typedef struct functionsLibEngineStats {
    size_t n_lib;       /* Number of libraries using this engine */
    size_t n_functions; /* Number of functions across those libraries */
} functionsLibEngineStats;
```

## Library Metadata Format

Function libraries must start with a shebang line specifying the engine and library name:

```
#!lua name=mylib
```

`functionExtractLibMetaData()` parses this header:

```c
int functionExtractLibMetaData(sds payload, functionsLibMetaData *md, sds *err);
```

It extracts:
- **engine**: characters after `#!` in the first token (e.g., `lua`)
- **name**: value from `name=` parameter

The code following the shebang newline is passed to the engine for compilation.

## FUNCTION LOAD

Entry point: `functionLoadCommand()`. Core logic in `functionsCreateWithLibraryCtx()`:

```c
sds functionsCreateWithLibraryCtx(sds code, int replace, sds *err,
                                  functionsLibCtx *lib_ctx, size_t timeout);
```

Flow:

1. Parse metadata with `functionExtractLibMetaData()`.
2. Validate library name (alphanumeric + underscore).
3. Look up the scripting engine by name.
4. If `replace` is false and library already exists, return error.
5. If replacing, unlink the old library.
6. Create a new `functionLibInfo` via `engineLibraryCreate()`.
7. Call `scriptingEngineCallCompileCode()` with `VMSE_FUNCTION` - the engine returns an array of `compiledFunction` objects (one per registered function).
8. For each compiled function, call `functionLibCreateFunction()` which validates the name and adds it to the library's function dict.
9. Verify at least one function was registered.
10. Check for function name collisions with existing libraries.
11. Link the new library into the context via `libraryLink()`.

The load timeout defaults to `LOAD_TIMEOUT_MS` (500ms). Replicated loads use timeout 0 (unlimited).

## FCALL / FCALL_RO

Entry point: `fcallCommand()` / `fcallroCommand()`, both call `fcallCommandGeneric()`:

```c
static void fcallCommandGeneric(client *c, int ro);
```

Flow:

1. Look up the function by name in `curr_functions_lib_ctx->functions`.
2. Get the `scriptingEngine` from the function's library.
3. Parse `numkeys` from argv[2].
4. Call `scriptPrepareForRun()` with the function's per-function flags (`fi->compiled_function->f_flags`).
5. Call `scriptingEngineCallFunction()` with `VMSE_FUNCTION`.
6. Call `scriptResetRun()`.

Note: Unlike EVAL, the `SCRIPT_EVAL_MODE` flag is NOT set on the run context, which affects error messages and SCRIPT KILL vs FUNCTION KILL behavior.

## FUNCTION DELETE

`functionDeleteCommand()` unlinks the library from the context and frees it. Sets `server.dirty++` for replication/persistence.

## FUNCTION LIST

`functionListCommand()` supports optional `LIBRARYNAME pattern` filtering and `WITHCODE` to include source. For each library it returns: library name, engine name, and a list of functions (each with name, description, and flags).

## FUNCTION STATS

`functionStatsCommand()` reports:
- **running_script**: name, command, and duration of any currently executing function.
- **engines**: per-engine library and function counts from `engines_stats`.

## FUNCTION DUMP / RESTORE

**DUMP** serializes all libraries using the RDB format (`rdbSaveFunctions()`), appends the RDB version and CRC64 checksum.

**RESTORE** deserializes libraries from a payload with three restore policies:
- `FLUSH`: Replace all existing libraries (swaps the entire `functionsLibCtx`).
- `APPEND`: Add new libraries; abort on any name collision.
- `REPLACE`: Add new libraries; on collision, replace the old library.

`libraryJoin()` handles the APPEND/REPLACE merge logic with rollback support - if a function name collides after libraries are unlinked, old libraries are re-linked.

## FUNCTION FLUSH

`functionFlushCommand()` calls `functionReset()` which releases the current context and reinitializes:

```c
void functionReset(int async, void(callback)(dict *));
```

The async path uses `freeFunctionsAsync()` for lazy freeing and collects engine reset callbacks.

## Library Linking

`libraryLink()` and `libraryUnlink()` manage the bidirectional relationship between `functionsLibCtx` and `functionLibInfo`:

- **Link**: adds each function to the global `functions` dict, adds the library to `libraries` dict, updates memory tracking and engine stats.
- **Unlink**: removes each function from the global dict, removes the library, decrements stats.

## Command Flag Extraction

```c
uint64_t fcallGetCommandFlags(client *c, uint64_t cmd_flags);
```

Called before execution to extract per-function flags. Looks up the function in the current context and converts its `f_flags` to command flags via `scriptFlagsToCmdFlags()`. The result is cached in `c->cur_script` to avoid a second lookup during execution.

## Persistence and Replication

Functions are saved to RDB using `RDB_OPCODE_FUNCTION2` opcodes. Each library is stored with its name, engine name, and full source code. On load, `rdbFunctionLoad()` calls `functionsCreateWithLibraryCtx()` to recompile.

Functions are replicated as commands: `FUNCTION LOAD`, `FUNCTION DELETE`, and `FUNCTION FLUSH` propagate to replicas via the normal command replication path. Individual FCALL invocations are NOT replicated as FCALL - the underlying write commands executed within the function are replicated individually (effects-based replication).

## Memory Accounting

```c
unsigned long functionsMemory(void);         /* Engine VM memory for VMSE_FUNCTION */
unsigned long functionsMemoryOverhead(void); /* Struct/dict overhead */
unsigned long functionsNum(void);            /* Total function count */
unsigned long functionsLibNum(void);         /* Total library count */
```

## Initialization

```c
int functionsInit(void);
```

Called at startup. Creates the initial `functionsLibCtx` and assigns it to `curr_functions_lib_ctx`. Engine stats entries are populated by iterating all registered engines via `scriptingEngineManagerForEachEngine()`.

## See Also

- [EVAL Subsystem](../scripting/eval.md) - The legacy ad-hoc scripting interface. Functions supersede EVAL by providing named identity, persistence, and library grouping.
- [Scripting Engine Architecture](../scripting/scripting-engine.md) - The pluggable engine layer that compiles and executes function libraries.
- [MULTI/EXEC Transactions](../transactions/multi-exec.md) - An alternative atomicity mechanism. Transactions queue commands for atomic execution; functions run as a single atomic unit with full scripting-language control flow.
- [Commandlog](../monitoring/commandlog.md) - Long-running FCALL invocations appear as slow commands in the commandlog, measured by `c->duration` wall-clock time.
- [ACL Subsystem](../security/acl.md) - FCALL execution is subject to ACL permission checks. The `scripting` command category controls access to FCALL/FCALL_RO.
