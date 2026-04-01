# ACL API - Authentication, Authorization, Module Users

Use when implementing custom authentication, checking permissions against ACL rules, creating module-managed users, or adding ACL log entries from a module.

Source: `src/module.c` (lines 8170-8490, 9987-10525, 14440-14475), `src/valkeymodule.h`

## Contents

- [Module Users](#module-users)
- [ACL String Management](#acl-string-management)
- [Permission Checking](#permission-checking)
- [ACL Logging](#acl-logging)
- [Authentication](#authentication)
- [Auth Callbacks](#auth-callbacks)
- [Blocking Auth](#blocking-auth)
- [Utility Functions](#utility-functions)

---

## Module Users

```c
ValkeyModuleUser *ValkeyModule_CreateModuleUser(const char *name);
int ValkeyModule_FreeModuleUser(ValkeyModuleUser *user);
```

Creates an ACL user managed by the module. Module users are not listed by the `ACL` command and are not checked for duplicate names. The caller is responsible for uniqueness.

When `FreeModuleUser` is called, all clients authenticated with that user are disconnected. Only free a user when you intend to invalidate it.

```c
ValkeyModuleUser *user = ValkeyModule_CreateModuleUser("mymod-readonly");
ValkeyModule_SetModuleUserACL(user, "allcommands");
ValkeyModule_SetModuleUserACL(user, "allkeys");
/* ... later ... */
ValkeyModule_FreeModuleUser(user);
```

To get a reference to an existing server ACL user:

```c
ValkeyModuleUser *ValkeyModule_GetModuleUserFromUserName(ValkeyModuleString *name);
```

Returns NULL if the user does not exist. The returned user must be freed with `FreeModuleUser`, but the underlying ACL user is not deleted (only the wrapper is freed). Only valid within the current context - store the name and re-fetch if needed later.

## ACL String Management

```c
int ValkeyModule_SetModuleUserACL(ValkeyModuleUser *user, const char *acl);
```

Sets a single ACL operation using `ACL SETUSER` syntax. Call multiple times for multiple rules.

```c
int ValkeyModule_SetModuleUserACLString(ValkeyModuleCtx *ctx,
                                        ValkeyModuleUser *user,
                                        const char *acl,
                                        ValkeyModuleString **error);
```

Sets the complete ACL string at once (like the `ACL SETUSER` command line). Returns `VALKEYMODULE_ERR` on invalid ACL, with the error description in `*error` if provided.

```c
ValkeyModuleString *ValkeyModule_GetModuleUserACLString(ValkeyModuleUser *user);
```

Returns the ACL description string for the user.

## Permission Checking

**Comprehensive check (recommended):**

```c
int ValkeyModule_ACLCheckPermissions(ValkeyModuleUser *user,
                                     ValkeyModuleString **argv,
                                     int argc,
                                     int dbid,
                                     ValkeyModuleACLLogEntryReason *denial_reason);
```

Validates command, key, channel, and database permissions. Returns `VALKEYMODULE_OK` or `VALKEYMODULE_ERR` with errno `EINVAL` (bad args) or `EACCES` (denied). The optional `denial_reason` output indicates what failed.

**Individual checks:**

```c
int ValkeyModule_ACLCheckCommandPermissions(ValkeyModuleUser *user,
                                            ValkeyModuleString **argv, int argc);
int ValkeyModule_ACLCheckKeyPermissions(ValkeyModuleUser *user,
                                        ValkeyModuleString *key, int flags);
int ValkeyModule_ACLCheckKeyPrefixPermissions(ValkeyModuleUser *user,
                                               const char *key, size_t len,
                                               unsigned int flags);
int ValkeyModule_ACLCheckChannelPermissions(ValkeyModuleUser *user,
                                             ValkeyModuleString *ch, int flags);
```

Key permission flags:

| Flag | Description |
|------|-------------|
| `VALKEYMODULE_CMD_KEY_ACCESS` | Read access |
| `VALKEYMODULE_CMD_KEY_UPDATE` | Modify existing |
| `VALKEYMODULE_CMD_KEY_INSERT` | Create new |
| `VALKEYMODULE_CMD_KEY_DELETE` | Delete |

Channel permission flags:

| Flag | Description |
|------|-------------|
| `VALKEYMODULE_CMD_CHANNEL_PUBLISH` | Publish |
| `VALKEYMODULE_CMD_CHANNEL_SUBSCRIBE` | Subscribe |
| `VALKEYMODULE_CMD_CHANNEL_UNSUBSCRIBE` | Unsubscribe (always allowed) |
| `VALKEYMODULE_CMD_CHANNEL_PATTERN` | Pattern-based channel |

Note: Since Valkey 9.1, `ACLCheckCommandPermissions` passes -1 for the database ID, which means it does not validate database permissions at all. For users without the `alldbs` flag, this causes READ or WRITE commands to be denied even if the user has permission for the current database. Use `ACLCheckPermissions` for comprehensive validation including database access.

## ACL Logging

```c
int ValkeyModule_ACLAddLogEntry(ValkeyModuleCtx *ctx,
                                ValkeyModuleUser *user,
                                ValkeyModuleString *object,
                                ValkeyModuleACLLogEntryReason reason);

int ValkeyModule_ACLAddLogEntryByUserName(ValkeyModuleCtx *ctx,
                                          ValkeyModuleString *username,
                                          ValkeyModuleString *object,
                                          ValkeyModuleACLLogEntryReason reason);
```

Log entry reasons:

| Constant | Description |
|----------|-------------|
| `VALKEYMODULE_ACL_LOG_AUTH` | Authentication failure |
| `VALKEYMODULE_ACL_LOG_CMD` | Command authorization failure |
| `VALKEYMODULE_ACL_LOG_KEY` | Key authorization failure |
| `VALKEYMODULE_ACL_LOG_CHANNEL` | Channel authorization failure |
| `VALKEYMODULE_ACL_LOG_DB` | Database authorization failure |

## Authentication

```c
int ValkeyModule_AuthenticateClientWithUser(ValkeyModuleCtx *ctx,
                                            ValkeyModuleUser *module_user,
                                            ValkeyModuleUserChangedFunc callback,
                                            void *privdata,
                                            uint64_t *client_id);

int ValkeyModule_AuthenticateClientWithACLUser(ValkeyModuleCtx *ctx,
                                                const char *name, size_t len,
                                                ValkeyModuleUserChangedFunc callback,
                                                void *privdata,
                                                uint64_t *client_id);
```

Authenticate the current context's client. Returns `VALKEYMODULE_ERR` if the user is disabled or (for `WithACLUser`) does not exist.

The optional callback fires when the client's user changes (AUTH command, disconnect, etc.) - use it to clean up module state. It fires exactly once. Pass NULL for callback and privdata if tracking is not needed.

The `client_id` output can be used later with `DeauthenticateAndCloseClient`.

```c
int ValkeyModule_DeauthenticateAndCloseClient(ValkeyModuleCtx *ctx,
                                               uint64_t client_id);
```

Revokes authentication and schedules the client for closing. Not thread-safe.

## Auth Callbacks

```c
void ValkeyModule_RegisterAuthCallback(ValkeyModuleCtx *ctx,
                                       ValkeyModuleAuthCallback cb);
```

Registers a module authentication callback invoked during AUTH/HELLO commands. Callbacks are tried in reverse registration order (most recently registered first). The callback signature:

```c
int auth_cb(ValkeyModuleCtx *ctx, ValkeyModuleString *username,
            ValkeyModuleString *password, ValkeyModuleString **err);
```

Return values:

| Return | Action |
|--------|--------|
| `VALKEYMODULE_AUTH_HANDLED` | Auth succeeded (if `AuthenticateClient*` was called) or denied |
| `VALKEYMODULE_AUTH_NOT_HANDLED` | Skip to next callback |

To deny auth, return `VALKEYMODULE_AUTH_HANDLED` without calling any `AuthenticateClient*` function. Set `*err` for a custom error message (freed automatically by the server).

## Blocking Auth

```c
ValkeyModuleBlockedClient *ValkeyModule_BlockClientOnAuth(
    ValkeyModuleCtx *ctx,
    ValkeyModuleAuthCallback reply_callback,
    void (*free_privdata)(ValkeyModuleCtx *, void *));
```

Blocks a client during auth for async operations (e.g. external auth service). Only callable within a `RegisterAuthCallback` handler. The reply callback should authenticate, deny, or skip handling. Use `ValkeyModule_UnblockClient` to trigger the reply callback.

## Utility Functions

```c
ValkeyModuleString *ValkeyModule_GetCurrentUserName(ValkeyModuleCtx *ctx);
void ValkeyModule_SetContextUser(ValkeyModuleCtx *ctx,
                                  const ValkeyModuleUser *user);
ValkeyModuleString *ValkeyModule_GetClientCertificate(ValkeyModuleCtx *ctx,
                                                      uint64_t client_id);
int ValkeyModule_RedactClientCommandArgument(ValkeyModuleCtx *ctx, int pos);
```

- `GetCurrentUserName` - returns username of context's client (free with `FreeString`)
- `SetContextUser` - overrides the user for subsequent `ValkeyModule_Call` with `C` flag
- `GetClientCertificate` - returns X.509 PEM certificate (NULL if no TLS or no cert)
- `RedactClientCommandArgument` - hides argument at position from SLOWLOG/MONITOR (pos > 0)

## See Also

- [calling-commands.md](calling-commands.md) - Using the `C` flag for ACL-checked calls
- [client-info.md](client-info.md) - Client identity, GetClientUserNameById, and RedactClientCommandArgument
- [command-filter.md](command-filter.md) - Command filtering that complements ACL checks
- [../commands/registration.md](../commands/registration.md) - Command ACL categories
- [../lifecycle/module-loading.md](../lifecycle/module-loading.md) - Module initialization context
