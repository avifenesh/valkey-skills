# ACL Subsystem

Use when understanding Valkey's access control internals - user management,
permission checking, command categories, key/channel patterns, selectors,
persistence, and audit logging.

Source: `src/acl.c` (~3,500 lines), structs in `src/server.h`.

## Contents

- Global State (line 27)
- Core Structs (line 36)
- Selector Model (line 78)
- Command Bitmap (line 110)
- Command Categories (line 122)
- ACLSetUser - The Rule Engine (line 143)
- Authentication Flow (line 187)
- Permission Checking (line 204)
- Default User (line 233)
- Persistence (line 241)
- ACL LOG - Audit System (line 272)
- User Deletion and Rule Ordering (line 287)
- See Also (line 300)

---

## Global State

`ACLInit()` creates: `Users` (rax tree mapping names to user structs),
`ACLLog` (audit log list), `DefaultUser` (full-permissions default), and
`UsersToLoad` (deferred config-file users). A separate `commandId` rax maps
command names to sequential bitmap IDs.

---

## Core Structs

### user (server.h:1073)

```c
typedef struct user {
    sds name;         /* Username as SDS string */
    uint32_t flags;   /* USER_FLAG_* bitmask */
    list *passwords;  /* List of SHA-256 hex hashed passwords */
    list *selectors;  /* List of aclSelector; first is always the root selector */
    robj *acl_string; /* Cached string representation, invalidated on change */
} user;
```

Flags: `ENABLED` (bit 0), `DISABLED` (1), `NOPASS` (2 - any password works),
`SANITIZE_PAYLOAD` (3 - default), `SANITIZE_PAYLOAD_SKIP` (4).

### aclSelector (acl.c:159, private)

```c
typedef struct {
    uint32_t flags;                                     /* SELECTOR_FLAG_* */
    uint64_t allowed_commands[USER_COMMAND_BITS_COUNT/64]; /* Command bitmap */
    sds **allowed_firstargs;  /* Per-command first-arg allowlists (deprecated path) */
    list *patterns;           /* List of keyPattern structs */
    list *channels;           /* List of SDS channel patterns */
    sds command_rules;        /* Ordered string of +/-commands and +/-@categories */
    intset *dbs;              /* Allowed database IDs */
} aclSelector;
```

Selector flags: `ROOT` (bit 0 - implicit root), `ALLKEYS` (1), `ALLCOMMANDS`
(2), `ALLCHANNELS` (3), `ALLDBS` (4).

### keyPattern (acl.c:303)

A `keyPattern` pairs a glob `pattern` (SDS) with `flags`:
`ACL_READ_PERMISSION` (1), `ACL_WRITE_PERMISSION` (2), or both (3).
`~pattern` grants full access, `%R~pattern` read-only, `%W~pattern` write-only.

---

## Selector Model

Each user has a linked list of selectors. The first selector is always the
"root" selector (flag `SELECTOR_FLAG_ROOT`), which provides backwards
compatibility with pre-selector ACL syntax.

When checking permissions, selectors are evaluated sequentially. If any
selector grants the operation, it succeeds (`ACL_OK`). This is an OR
relationship - the user needs to match only one selector.

```c
/* Permission check iterates all selectors */
listRewind(u->selectors, &li);
while ((ln = listNext(&li))) {
    aclSelector *s = listNodeValue(ln);
    int acl_retval = ACLSelectorCheckCmd(s, cmd, argv, argc, &local_idxptr, &cache, dbid);
    if (acl_retval == ACL_OK) return ACL_OK;
}
```

Additional selectors are created via parenthesized blocks in ACL SETUSER:

```
ACL SETUSER myuser on >pass ~cache:* +get (+@write ~data:*)
```

This creates a root selector (`~cache:* +get`) plus one additional selector
(`+@write ~data:*`). The user can GET keys matching `cache:*` OR write to
keys matching `data:*`.

---

## Command Bitmap

Each command gets a sequential ID via `ACLGetCommandID()`, stored in a radix
tree and reused across module load/unload. The bitmap is 1024 bits (16 uint64
words). Bit 1023 is reserved as a "future commands" flag - set by `+@all`,
it determines whether serialization starts with `+@all` or `-@all`.

Subcommands get their own IDs. Allowing a parent (`+client`) sets bits for all
its subcommands.

---

## Command Categories

21 built-in categories, each a bit in a uint64 bitmask:

```
keyspace, read, write, set, sortedset, list, hash, string, bitmap,
hyperloglog, geo, stream, pubsub, admin, fast, slow, blocking,
dangerous, connection, transaction, scripting
```

Modules can register additional categories at runtime via
`ACLAddCommandCategory()`. Maximum 64 total categories (limited by the
`uint64_t` bitmask). Categories are applied using `+@category` or `-@category`
syntax.

When a category rule is applied, the `command_rules` string is updated so the
relative ordering of category and command rules is preserved. This is critical
for correct serialization - rules are order-dependent.

---

## ACLSetUser - The Rule Engine

`ACLSetUser(user *u, const char *op, ssize_t oplen)` is the central function
that applies a single rule to a user. Rules handled at the user level:

| Rule | Effect |
|------|--------|
| `on` / `off` | Enable/disable user |
| `nopass` | Accept any password, clear password list |
| `resetpass` | Clear password list, clear nopass flag |
| `>password` | Add SHA-256 hash of password to list |
| `#hexhash` | Add pre-hashed password directly |
| `<password` | Remove password by plaintext |
| `!hexhash` | Remove password by hash |
| `reset` | Full reset: off, resetpass, resetkeys, resetchannels, -@all, clearselectors |
| `(...)` | Create and attach a new selector |
| `clearselectors` | Remove all non-root selectors |

Any rule not handled at user level is delegated to `ACLSetSelector()` on the
root selector. Selector-level rules:

| Rule | Effect |
|------|--------|
| `allkeys` / `~*` | Grant access to all keys |
| `resetkeys` | Remove all key patterns |
| `allchannels` / `&*` | Grant access to all channels |
| `resetchannels` | Remove all channel patterns |
| `alldbs` | Grant access to all databases |
| `resetdbs` | Remove all database grants |
| `db=N` | Grant access to specific database |
| `allcommands` / `+@all` | Grant all commands (sets future-commands bit) |
| `nocommands` / `-@all` | Deny all commands |
| `~pattern` | Add key pattern with read+write |
| `%R~pattern` | Add key pattern with read-only |
| `%W~pattern` | Add key pattern with write-only |
| `&pattern` | Add channel pattern |
| `+command` | Allow a specific command |
| `-command` | Deny a specific command |
| `+@category` | Allow an entire category |
| `-@category` | Deny an entire category |
| `+command\|subcommand` | Allow a specific subcommand |

---

## Authentication Flow

```
ACLAuthenticateUser(client, username, password, &err)
  -> checkModuleAuthentication()   /* Modules get first shot */
  -> checkPasswordBasedAuth()      /* Falls through if modules don't handle */
       -> ACLCheckUserCredentials() /* Hash comparison, timing-safe */
```

Password comparison uses `time_independent_strcmp()` - a constant-time
comparison that XORs each byte and accumulates the diff, preventing timing
side-channel attacks. Passwords are stored as SHA-256 hex strings (64 chars).

On authentication failure, an `ACL_DENIED_AUTH` entry is added to the ACL log.

---

## Permission Checking

The high-level entry point is `ACLCheckAllPerm(client *c, int *idxptr)`:

```c
int ACLCheckAllPerm(client *c, int *idxptr) {
    int dbid = (c->flag.multi) ? c->mstate->transaction_db_id : c->db->id;
    return ACLCheckAllUserCommandPerm(c->user, c->cmd, c->argv, c->argc, dbid, idxptr);
}
```

Return codes (priority order for multi-selector error reporting):

| Code | Meaning |
|------|---------|
| `ACL_OK` (0) | Permission granted |
| `ACL_DENIED_DB` (1) | Database access denied |
| `ACL_DENIED_CMD` (2) | Command execution denied |
| `ACL_DENIED_KEY` (3) | Key access denied |
| `ACL_DENIED_AUTH` (4) | Authentication failure (ACL LOG only) |
| `ACL_DENIED_CHANNEL` (5) | Pub/sub channel denied |
| `ACL_INVALID_TLS_CERT_AUTH` (6) | TLS certificate auth failure |

Key permission checking (`ACLSelectorCheckKey`) maps command key-spec flags
to ACL permissions: `CMD_KEY_ACCESS` maps to read, while `CMD_KEY_INSERT`,
`CMD_KEY_DELETE`, and `CMD_KEY_UPDATE` map to write.

---

## Default User

`ACLCreateDefaultUser()` sets `+@all ~* &* on nopass alldbs` - full
permissions, enabled, no password. Every new connection authenticates as
`default` until AUTH or HELLO switches to another user. Cannot be deleted.

---

## Persistence

Two mutually exclusive persistence mechanisms. Mixing them causes a fatal
startup error.

### ACL file (aclfile config option)

`ACLLoadFromFile()` reads the file, creates a fresh `Users` radix tree, parses
each line as `user <name> <rules...>`, validates all rules, then atomically
swaps the tree. On any parse error, the old tree is restored and no changes
take effect.

`ACLSaveToFile()` serializes all users via `ACLDescribeUser()`, writes to a
temp file, fsyncs, then atomically renames over the target.

### Config file (user directives in valkey.conf)

`ACLAppendUserForLoading()` collects user definitions during config parsing.
Rules are validated against a temporary "fake user" at parse time.
`ACLLoadConfiguredUsers()` applies them after modules are loaded, since module
commands need to be registered first.

### Startup sequence

`ACLLoadUsersAtStartup()` runs after modules are loaded:
1. Check that aclfile and config-file users are not both set (fatal error)
2. Load config-file users via `ACLLoadConfiguredUsers()`
3. If aclfile is set, load it via `ACLLoadFromFile()`

---

## ACL LOG - Audit System

`ACLLogEntry` records: `reason` (ACL_DENIED_* code), `context` (toplevel/lua/
multi/module/script), `object` (key or command name), `username`, `cinfo`
(client info), `entry_id`, timestamps, and a dedup `count`.

Deduplication: entries with same reason/context/object/username within 60
seconds (`ACL_LOG_GROUPING_MAX_TIME_DELTA`) increment `count` instead of
creating new entries. Log is capped at `server.acllog_max_len`, trimmed from
the tail. `ACL LOG RESET` clears all entries.

Per-reason counters are also tracked in `server.acl_info` for INFO output.

---

## User Deletion and Rule Ordering

On deletion, `ACLFreeUserAndKillClients()` reassigns all connected clients of
that user to `DefaultUser` and schedules async disconnection.

Each selector's `command_rules` field stores rules in application order. This
matters because `+@all -@dangerous` differs from `-@all +@dangerous`. On
serialization, rules are replayed against a fresh selector and the resulting
bitmap is compared to the original. A mismatch triggers `serverPanic()` - ACL
serialization errors are treated as security risks.

---
