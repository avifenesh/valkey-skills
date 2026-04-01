# RDB Stream API - Full-File RDB Load and Save

Use when a module needs to trigger a full RDB load or save programmatically, implementing backup/restore module commands, loading an RDB snapshot from a file, saving the entire dataset to a custom file path, or building snapshot-based migration tools.

Source: `src/module.c` (lines 13668-13800)

## Contents

- [Overview](#overview)
- [RdbStreamCreateFromFile](#rdbstreamcreatefromfile)
- [RdbStreamFree](#rdbstreamfree)
- [RdbLoad](#rdbload)
- [RdbSave](#rdbsave)
- [When to use this API](#when-to-use-this-api)

---

## Overview

The RDB Stream API provides module-level access to full dataset serialization and deserialization. Unlike the per-key `rdb_load`/`rdb_save` callbacks (which the server calls for each key of your type), these functions let a module trigger a complete RDB save or load of the entire server dataset to/from a file.

This is a server-wide operation - it saves or loads all keys across all databases, not just module type keys.

The API uses a stream abstraction (`ValkeyModuleRdbStream`) that currently supports file-based streams only.

## RdbStreamCreateFromFile

```c
ValkeyModuleRdbStream *ValkeyModule_RdbStreamCreateFromFile(const char *filename);
```

Creates an RDB stream object for file-based I/O. The returned pointer is owned by the caller and must be freed with `ValkeyModule_RdbStreamFree()`.

| Parameter | Description |
|---|---|
| `filename` | Path to the RDB file to read from or write to |

The stream object is reusable for both load and save operations but is typically created, used once, and freed.

## RdbStreamFree

```c
void ValkeyModule_RdbStreamFree(ValkeyModuleRdbStream *stream);
```

Releases the memory associated with an RDB stream object. Must be called after the load or save operation completes.

## RdbLoad

```c
int ValkeyModule_RdbLoad(ValkeyModuleCtx *ctx, ValkeyModuleRdbStream *stream, int flags);
```

Loads an RDB file from the stream, **replacing the entire current dataset**. This is a destructive operation - all existing data is cleared before loading.

| Parameter | Description |
|---|---|
| `ctx` | Module context |
| `stream` | RDB stream created with `RdbStreamCreateFromFile` |
| `flags` | Must be 0 (reserved for future use) |

**Returns:** `VALKEYMODULE_OK` on success, `VALKEYMODULE_ERR` on failure with `errno` set.

**Error codes:**

| errno | Condition |
|---|---|
| `EINVAL` | `stream` is NULL or `flags` is non-zero |
| `ENOTSUP` | Called on a replica (not allowed) |
| `ENOENT` | RDB file does not exist |
| `EIO` | RDB file is corrupt or read error |

**Side effects:**

- All existing data is cleared
- Connected replicas are disconnected
- Replication backlog is freed
- Any running AOF rewrite child is killed
- Any running RDB save child is killed
- Any running slot migration child is killed
- AOF is stopped before load and restarted after if `aof_enabled` is set
- The current client (if any) is protected during the load to prevent re-entry

**Example:**

```c
int MyModule_LoadRDB(ValkeyModuleCtx *ctx, ValkeyModuleString **argv, int argc) {
    const char *filename = ValkeyModule_StringPtrLen(argv[1], NULL);

    ValkeyModuleRdbStream *s = ValkeyModule_RdbStreamCreateFromFile(filename);
    int ret = ValkeyModule_RdbLoad(ctx, s, 0);
    ValkeyModule_RdbStreamFree(s);

    if (ret != VALKEYMODULE_OK) {
        return ValkeyModule_ReplyWithError(ctx, "ERR failed to load RDB");
    }
    return ValkeyModule_ReplyWithSimpleString(ctx, "OK");
}
```

## RdbSave

```c
int ValkeyModule_RdbSave(ValkeyModuleCtx *ctx, ValkeyModuleRdbStream *stream, int flags);
```

Saves the entire current dataset to the stream as an RDB file.

| Parameter | Description |
|---|---|
| `ctx` | Module context |
| `stream` | RDB stream created with `RdbStreamCreateFromFile` |
| `flags` | Must be 0 (reserved for future use) |

**Returns:** `VALKEYMODULE_OK` on success, `VALKEYMODULE_ERR` on failure with `errno` set.

**Error codes:**

| errno | Condition |
|---|---|
| `EINVAL` | `stream` is NULL or `flags` is non-zero |

The save is synchronous and blocks the server while writing. For large datasets, trigger this from a low-traffic context (e.g., a timer event or admin command) rather than during high-traffic periods.

**Example:**

```c
int MyModule_SaveRDB(ValkeyModuleCtx *ctx, ValkeyModuleString **argv, int argc) {
    const char *filename = ValkeyModule_StringPtrLen(argv[1], NULL);

    ValkeyModuleRdbStream *s = ValkeyModule_RdbStreamCreateFromFile(filename);
    int ret = ValkeyModule_RdbSave(ctx, s, 0);
    ValkeyModule_RdbStreamFree(s);

    if (ret != VALKEYMODULE_OK) {
        return ValkeyModule_ReplyWithError(ctx, "ERR failed to save RDB");
    }
    return ValkeyModule_ReplyWithSimpleString(ctx, "OK");
}
```

## When to Use This API

**Use the RDB Stream API when:**
- Building backup/restore module commands
- Implementing snapshot-based migration tools
- Creating a module that manages point-in-time recovery
- Testing by loading specific RDB fixtures

**Use per-key rdb_load/rdb_save callbacks instead when:**
- Defining how your custom data type persists during normal server RDB operations
- Handling encoding version changes for your type
- Your module only needs its own keys to be saved and loaded

The two APIs serve different purposes. The per-key callbacks (`rdb_load`/`rdb_save` in `ValkeyModuleTypeMethods`) define how individual keys of your type are serialized - the server calls these automatically during `BGSAVE`, `BGREWRITEAOF`, replication, etc. The RDB Stream API triggers a full server-level save or load operation that includes all keys of all types.

They also compose: when `ValkeyModule_RdbSave()` writes the dataset, it calls each module type's `rdb_save` callback for keys of that type. When `ValkeyModule_RdbLoad()` reads, it calls each type's `rdb_load` callback.
