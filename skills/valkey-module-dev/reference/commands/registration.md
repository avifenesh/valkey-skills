# Command Registration - CreateCommand, Flags, Key Specs, Subcommands

Use when registering new commands in a Valkey module, setting command flags, defining key specifications, creating subcommands, or adding argument metadata.

Source: `src/module.c` (lines 1104-2393), `src/valkeymodule.h`

## Contents

- [CreateCommand](#createcommand) (line 20)
- [Command Flags](#command-flags) (line 44)
- [CreateSubcommand](#createsubcommand) (line 73)
- [Key Position APIs](#key-position-apis) (line 93)
- [SetCommandInfo](#setcommandinfo) (line 114)
- [Key Spec Structure](#key-spec-structure) (line 139)
- [Argument Metadata](#argument-metadata) (line 174)
- [ACL Categories](#acl-categories) (line 199)

---

## CreateCommand

```c
int ValkeyModule_CreateCommand(ValkeyModuleCtx *ctx,
                               const char *name,
                               ValkeyModuleCmdFunc cmdfunc,
                               const char *strflags,
                               int firstkey, int lastkey, int keystep);
```

Must be called during `ValkeyModule_OnLoad()`. The callback signature:

```c
int MyCommand(ValkeyModuleCtx *ctx, ValkeyModuleString **argv, int argc);
```

Key position parameters (1-based index, 0 for commands with no keys):

- `firstkey` - index of first key argument
- `lastkey` - index of last key (-1 = last argument provided)
- `keystep` - step between key indexes

Returns `VALKEYMODULE_OK` on success, `VALKEYMODULE_ERR` if called outside `OnLoad`, command name is busy/invalid, flags are invalid, or the command has the `no-cluster` flag and the server has cluster mode enabled.

## Command Flags

Pass as space-separated string to `strflags` parameter:

| Flag | Meaning |
|------|---------|
| `write` | Command may modify data |
| `readonly` | Returns data, never writes |
| `admin` | Administrative command |
| `deny-oom` | Deny during out-of-memory |
| `deny-script` | Disallow in Lua scripts |
| `allow-loading` | Allow while server loads data |
| `pubsub` | Publishes on Pub/Sub channels |
| `fast` | Time complexity <= O(log N) |
| `blocking` | May block the client |
| `allow-stale` | Allow on replicas with stale data |
| `no-monitor` | Don't show in MONITOR (sensitive data) |
| `no-commandlog` | Don't log in command log (sensitive data) |
| `no-slowlog` | Deprecated alias for `no-commandlog` |
| `random` | Deprecated since Redis OSS 7.0 - silently ignored; use command tips instead |
| `no-auth` | Allow unauthenticated clients |
| `may-replicate` | May generate replication traffic |
| `no-mandatory-keys` | All keys are optional |
| `allow-busy` | Permit while server is blocked |
| `all-dbs` | Accesses all databases |
| `getkeys-api` | Uses custom key position reporting |
| `getchannels-api` | Uses custom channel position reporting |
| `no-cluster` | Not designed for cluster mode |

## CreateSubcommand

```c
int ValkeyModule_CreateSubcommand(ValkeyModuleCommand *parent,
                                  const char *name,
                                  ValkeyModuleCmdFunc cmdfunc,
                                  const char *strflags,
                                  int firstkey, int lastkey, int keystep);
```

Parent must be created with `cmdfunc = NULL` (pure container). Only one nesting level allowed.

```c
/* Example: MODULE.CONFIG GET|SET */
ValkeyModule_CreateCommand(ctx, "module.config", NULL, "", 0, 0, 0);
ValkeyModuleCommand *parent = ValkeyModule_GetCommand(ctx, "module.config");
ValkeyModule_CreateSubcommand(parent, "set", cmd_config_set, "", 0, 0, 0);
ValkeyModule_CreateSubcommand(parent, "get", cmd_config_get, "", 0, 0, 0);
```

## Key Position APIs

For commands where first/last/step is insufficient, use `getkeys-api` flag:

```c
int ValkeyModule_IsKeysPositionRequest(ValkeyModuleCtx *ctx);
void ValkeyModule_KeyAtPosWithFlags(ValkeyModuleCtx *ctx, int pos, int flags);
```

```c
if (ValkeyModule_IsKeysPositionRequest(ctx)) {
    ValkeyModule_KeyAtPosWithFlags(ctx, 1,
        VALKEYMODULE_CMD_KEY_RW | VALKEYMODULE_CMD_KEY_UPDATE);
    ValkeyModule_KeyAtPosWithFlags(ctx, 2,
        VALKEYMODULE_CMD_KEY_RO | VALKEYMODULE_CMD_KEY_ACCESS);
    return VALKEYMODULE_OK;
}
```

Channel position API follows the same pattern with `getchannels-api` flag, `IsChannelsPositionRequest()`, and `ChannelAtPosWithFlags()`.

## SetCommandInfo

```c
int ValkeyModule_SetCommandInfo(ValkeyModuleCommand *command,
                                const ValkeyModuleCommandInfo *info);
```

The `ValkeyModuleCommandInfo` struct:

```c
typedef struct {
    const ValkeyModuleCommandInfoVersion *version; /* VALKEYMODULE_COMMAND_INFO_VERSION */
    const char *summary;
    const char *complexity;
    const char *since;
    ValkeyModuleCommandHistoryEntry *history;      /* NULL-terminated array */
    const char *tips;                              /* space-separated */
    int arity;                                     /* positive = exact, negative = minimum */
    ValkeyModuleCommandKeySpec *key_specs;          /* zero-terminated array */
    ValkeyModuleCommandArg *args;                  /* zero-terminated array */
} ValkeyModuleCommandInfo;
```

Sets `errno` to `EINVAL` for invalid info or `EEXIST` if already set.

## Key Spec Structure

```c
typedef struct {
    const char *notes;
    uint64_t flags;                                /* VALKEYMODULE_CMD_KEY_* */
    ValkeyModuleKeySpecBeginSearchType begin_search_type;
    union { struct { int pos; } index;
            struct { const char *keyword; int startfrom; } keyword; } bs;
    ValkeyModuleKeySpecFindKeysType find_keys_type;
    union { struct { int lastkey; int keystep; int limit; } range;
            struct { int keynumidx; int firstkey; int keystep; } keynum; } fk;
} ValkeyModuleCommandKeySpec;
```

Key spec flags - exactly one access type required (RO/RW/OW/RM):

| Flag | Value | Meaning |
|------|-------|---------|
| `VALKEYMODULE_CMD_KEY_RO` | `1<<0` | Read-only access |
| `VALKEYMODULE_CMD_KEY_RW` | `1<<1` | Read-write access |
| `VALKEYMODULE_CMD_KEY_OW` | `1<<2` | Overwrite |
| `VALKEYMODULE_CMD_KEY_RM` | `1<<3` | Delete the key |
| `VALKEYMODULE_CMD_KEY_ACCESS` | `1<<4` | Returns/copies user data |
| `VALKEYMODULE_CMD_KEY_UPDATE` | `1<<5` | Updates existing data |
| `VALKEYMODULE_CMD_KEY_INSERT` | `1<<6` | Adds data, no modify/delete |
| `VALKEYMODULE_CMD_KEY_DELETE` | `1<<7` | Deletes content from value |
| `VALKEYMODULE_CMD_KEY_NOT_KEY` | `1<<8` | Not a key, but route as one |
| `VALKEYMODULE_CMD_KEY_INCOMPLETE` | `1<<9` | Spec may not cover all keys |
| `VALKEYMODULE_CMD_KEY_VARIABLE_FLAGS` | `1<<10` | Flags depend on arguments |

Begin search types: `VALKEYMODULE_KSPEC_BS_INVALID` (zero default for struct literals), `VALKEYMODULE_KSPEC_BS_UNKNOWN`, `VALKEYMODULE_KSPEC_BS_INDEX`, `VALKEYMODULE_KSPEC_BS_KEYWORD`.

Find keys types: `VALKEYMODULE_KSPEC_FK_OMITTED` (zero default for struct literals), `VALKEYMODULE_KSPEC_FK_UNKNOWN`, `VALKEYMODULE_KSPEC_FK_RANGE`, `VALKEYMODULE_KSPEC_FK_KEYNUM`.

## Argument Metadata

```c
typedef struct ValkeyModuleCommandArg {
    const char *name;
    ValkeyModuleCommandArgType type;
    int key_spec_index;    /* 0-based index into key_specs if type is KEY; -1 otherwise */
    const char *token;     /* If type is PURE_TOKEN, this is the token */
    const char *summary;
    const char *since;
    int flags;             /* VALKEYMODULE_CMD_ARG_* */
    const char *deprecated_since;
    struct ValkeyModuleCommandArg *subargs;  /* self-referencing requires named tag */
    const char *display_text;
} ValkeyModuleCommandArg;
```

| Arg Flag | Value | Meaning |
|----------|-------|---------|
| `VALKEYMODULE_CMD_ARG_OPTIONAL` | `1<<0` | Argument is optional |
| `VALKEYMODULE_CMD_ARG_MULTIPLE` | `1<<1` | May repeat |
| `VALKEYMODULE_CMD_ARG_MULTIPLE_TOKEN` | `1<<2` | Token repeats with argument |

Arg types: `STRING`, `INTEGER`, `DOUBLE`, `KEY`, `PATTERN`, `UNIX_TIME`, `PURE_TOKEN`, `ONEOF` (requires subargs), `BLOCK` (requires subargs).

## ACL Categories

```c
int ValkeyModule_AddACLCategory(ValkeyModuleCtx *ctx, const char *name);
int ValkeyModule_SetCommandACLCategories(ValkeyModuleCommand *command,
                                         const char *aclflags);
```

`AddACLCategory` creates a new category (max 64 total). `SetCommandACLCategories` assigns categories as space-separated string. Both must be called during `OnLoad`.

## See Also

- [reply-building.md](reply-building.md) - Reply functions for command implementations
- [string-objects.md](string-objects.md) - Parsing command arguments with ValkeyModuleString
- [key-generic.md](key-generic.md) - Opening and manipulating keys from commands
- [../lifecycle/context.md](../lifecycle/context.md) - Module context and context flags
- [../lifecycle/module-loading.md](../lifecycle/module-loading.md) - OnLoad where commands must be registered
- [../lifecycle/memory.md](../lifecycle/memory.md) - AutoMemory for automatic cleanup in command handlers
- [../advanced/acl.md](../advanced/acl.md) - ACL checking and authentication for commands
- [../scripting-engine.md](../scripting-engine.md) - Custom scripting engines as an alternative to commands
