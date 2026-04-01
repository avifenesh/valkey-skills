# EVAL Subsystem

Use when investigating EVAL/EVALSHA command behavior, Lua script caching, script eviction, shebang flag parsing, or the legacy eval-to-engine bridge.

Source files: `src/eval.c`, `src/script.c`, `src/script.h`

## Contents

- Overview (line 23)
- Key Data Structures (line 27)
- SHA1 Hashing (line 76)
- Script Registration (line 86)
- Shebang Flags (line 97)
- LRU Eviction (line 127)
- Command Entry Points (line 133)
- Script Execution Lifecycle (script.c) (line 165)
- Memory Accounting (line 177)
- Replication (line 186)

---

## Overview

The EVAL subsystem handles ad-hoc script execution via the `EVAL`, `EVALSHA`, `EVAL_RO`, and `EVALSHA_RO` commands, plus the `SCRIPT` management commands (LOAD, EXISTS, FLUSH, KILL, SHOW, DEBUG). Scripts are identified by their SHA1 hash and cached in an LRU-bounded dictionary. The subsystem does not embed a Lua interpreter directly - it delegates to the pluggable scripting engine layer (see `scripting-engine-architecture.md`).

## Key Data Structures

### evalScript

Represents a cached script in the eval dictionary:

```c
typedef struct evalScript {
    compiledFunction *script;   /* Engine-compiled function object */
    scriptingEngine *engine;    /* Which engine compiled this script */
    robj *body;                 /* Original script source */
    uint64_t flags;             /* Script flags (from shebang or EVAL_COMPAT_MODE) */
    listNode *node;             /* Position in scripts_lru_list (NULL for SCRIPT LOAD) */
} evalScript;
```

### evalCtx

Global eval context - the script cache:

```c
struct evalCtx {
    dict *scripts;                  /* SHA1 (sds) -> evalScript* */
    list *scripts_lru_list;         /* LRU eviction list of SHA1 strings */
    unsigned long long scripts_mem; /* Tracked memory for cached scripts */
} evalCtx;
```

The dictionary uses case-insensitive hashing (`dictStrCaseHash`) so SHA1 lookups are case-insensitive.

### scriptRunCtx

Defined in `script.h`, shared between EVAL and FCALL. Holds per-execution state:

```c
struct scriptRunCtx {
    scriptingEngine *engine;
    const char *funcname;
    client *original_client;
    serverDb *original_db;
    int flags;
    int repl_flags;
    monotime start_time;
    int slot;
};
```

Runtime flags include `SCRIPT_WRITE_DIRTY`, `SCRIPT_TIMEDOUT`, `SCRIPT_KILLED`, `SCRIPT_READ_ONLY`, `SCRIPT_ALLOW_OOM`, `SCRIPT_EVAL_MODE`, and `SCRIPT_ALLOW_CROSS_SLOT`.

## SHA1 Hashing

`sha1hex()` produces a 40-character lowercase hex digest used as the cache key:

```c
void sha1hex(char *digest, char *script, size_t len);
```

For EVAL, the hash is computed from the script body. For EVALSHA, the caller-provided SHA is lowercased in place (avoiding `tolower()` for performance).

## Script Registration

`evalRegisterNewScript()` handles both EVAL (inline) and SCRIPT LOAD paths:

1. Computes SHA1 if coming from SCRIPT LOAD (when `*sha == NULL`).
2. If the script already exists and was added via EVAL, SCRIPT LOAD promotes it by removing it from the LRU list (preventing future eviction).
3. Parses the shebang header via `evalExtractShebangFlags()` to determine engine name and script flags.
4. Looks up the engine via `scriptingEngineManagerFind()`.
5. Calls `scriptingEngineCallCompileCode()` with subsystem type `VMSE_EVAL`.
6. Stores the result in `evalCtx.scripts`.

## Shebang Flags

Scripts can declare an engine and flags via a shebang line:

```
#!lua flags=no-writes,allow-oom
```

`evalExtractShebangFlags()` parses this:

```c
int evalExtractShebangFlags(sds body,
                            char **out_engine,
                            uint64_t *out_flags,
                            ssize_t *out_shebang_len,
                            sds *err);
```

If no shebang is present, the engine defaults to `"lua"` and flags default to `SCRIPT_FLAG_EVAL_COMPAT_MODE`. The compat mode flag triggers legacy behavior in `scriptPrepareForRun()` - looser validation, no cluster/OOM/stale checks.

Available flags (from `scripts_flags_def` in `script.c`):

| Flag constant | String | Effect |
|---------------|--------|--------|
| `SCRIPT_FLAG_NO_WRITES` | `no-writes` | Script is read-only |
| `SCRIPT_FLAG_ALLOW_OOM` | `allow-oom` | Run even under memory pressure |
| `SCRIPT_FLAG_ALLOW_STALE` | `allow-stale` | Run on stale replicas |
| `SCRIPT_FLAG_NO_CLUSTER` | `no-cluster` | Refuse to run in cluster mode |
| `SCRIPT_FLAG_ALLOW_CROSS_SLOT` | `allow-cross-slot-keys` | Access keys in multiple slots |

## LRU Eviction

Scripts added via EVAL (not SCRIPT LOAD) are subject to LRU eviction, capped at `LRU_LIST_LENGTH` (500). `scriptsLRUAdd()` evicts the oldest scripts when the list is full. Each time an EVAL script is executed, it is moved to the tail of the LRU list. `server.stat_evictedscripts` tracks evictions.

Scripts loaded via SCRIPT LOAD have `es->node == NULL` and are never evicted.

## Command Entry Points

```c
void evalCommand(client *c);       /* EVAL */
void evalRoCommand(client *c);     /* EVAL_RO - delegates to evalCommand */
void evalShaCommand(client *c);    /* EVALSHA - validates 40-char SHA */
void evalShaRoCommand(client *c);  /* EVALSHA_RO - delegates to evalShaCommand */
void scriptCommand(client *c);     /* SCRIPT subcommands */
```

### evalGenericCommand flow

1. Parse `numkeys` from argv[2].
2. Compute or copy the SHA1 hash.
3. Look up the script in `evalCtx.scripts`.
4. If EVALSHA and not found, return `NOSCRIPT` error.
5. If EVAL and not found, register the new script.
6. Call `scriptPrepareForRun()` to set up the `scriptRunCtx` - this validates flags, checks cluster state, OOM, replication, and read-only constraints.
7. Set `SCRIPT_EVAL_MODE` flag on the run context.
8. Call `scriptingEngineCallFunction()` with `VMSE_EVAL`, passing keys and args.
9. Call `scriptResetRun()` to tear down the run context.
10. If the script has an LRU node, move it to the tail.

### SCRIPT subcommands

- **FLUSH [ASYNC|SYNC]**: Calls `evalReset()` which releases and reinitializes `evalCtx`.
- **EXISTS sha1 [sha1...]**: Checks `evalCtx.scripts` dictionary for each SHA.
- **LOAD script**: Calls `evalRegisterNewScript()` with `sha == NULL` (SCRIPT LOAD path).
- **KILL**: Calls `scriptKill(c, 1)` (the `1` indicates eval context).
- **SHOW sha1**: Returns the script body from the cache.
- **DEBUG YES|SYNC|NO [engine_name]**: Enables/disables interactive debugging for a scripting engine.

## Script Execution Lifecycle (script.c)

`scriptPrepareForRun()` validates the execution environment based on script flags:

- Non-compat mode scripts are checked for cluster restrictions, stale replica state, write permissions, disk error state, replica count, and OOM.
- Compat mode scripts only check for stale replica state.
- Sets `SCRIPT_READ_ONLY` flag for `_RO` commands or `no-writes` scripts.
- Sets `SCRIPT_ALLOW_OOM` and `SCRIPT_ALLOW_CROSS_SLOT` based on flags.
- Stores the current `scriptRunCtx` in a file-static `curr_run_ctx`.

`scriptInterrupt()` is called periodically by the engine during execution. After `server.busy_reply_threshold` milliseconds, it enters timed-out mode, processes events, and checks whether the script should be killed.

## Memory Accounting

```c
unsigned long evalMemory(void);         /* Engine VM memory across all engines */
unsigned long evalScriptsMemory(void);  /* Cache overhead: dict + evalScript structs + LRU nodes */
```

`evalMemory()` iterates all registered engines and sums their `VMSE_EVAL` memory info. `evalScriptsMemory()` returns the overhead of the dictionary, script objects, and LRU list nodes.

## Replication

Scripts are replicated by their body, not by SHA. The `es->body` field in `evalScript` stores the original source so that EVALSHA commands can be replicated as EVAL. The `repl_flags` field in `scriptRunCtx` defaults to `PROPAGATE_AOF | PROPAGATE_REPL`.
