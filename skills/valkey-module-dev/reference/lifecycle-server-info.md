# Server Info - Version, Time, Database, and Utility APIs

Use when checking the server version at runtime, measuring time in a module, selecting databases, generating random data, or replying with arity errors.

Source: `src/module.c` (lines 2448-2471, 3155-3166, 4013-4015, 11044-11060, 14059-14124)

## Contents

- Server Version (line 19)
- Time Measurement (line 51)
- Database Selection (line 93)
- Random Bytes (line 97)
- WrongArity (line 122)
- Feature Detection (line 126)
- See Also (line 146)

---

## Server Version

```c
int ValkeyModule_GetServerVersion(void);
```

Returns the server version as a packed integer in the format `0x00MMmmpp`:

| Component | Position | Meaning |
|-----------|----------|---------|
| `MM` | Bits 16-23 | Major version |
| `mm` | Bits 8-15 | Minor version |
| `pp` | Bits 0-7 | Patch version |

For example, version 9.0.3 returns `0x00090003`.

Extract components with bitwise operations:

```c
int ver = ValkeyModule_GetServerVersion();
int major = (ver >> 16) & 0xFF;
int minor = (ver >> 8) & 0xFF;
int patch = ver & 0xFF;

ValkeyModule_Log(ctx, "notice",
    "Running on Valkey %d.%d.%d", major, minor, patch);
```

Use this to conditionally enable features that depend on the server version, or to guard against APIs that may not exist in older versions.

Source: `src/module.c` (lines 14113-14115)

## Time Measurement

Four time-related APIs are available:

```c
mstime_t ValkeyModule_Milliseconds(void);
```

Returns the current UNIX time in milliseconds. Calls `mstime()` internally. Suitable for timestamps and coarse timing.

```c
ustime_t ValkeyModule_Microseconds(void);
```

Returns the current UNIX time in microseconds. Calls `ustime()` internally. Suitable for higher-precision timestamps.

```c
uint64_t ValkeyModule_MonotonicMicroseconds(void);
```

Returns a monotonic counter in microseconds relative to an arbitrary point. Uses `getMonotonicUs()` internally. This counter is not affected by system clock adjustments, making it ideal for measuring elapsed time and performance benchmarks.

```c
ustime_t ValkeyModule_CachedMicroseconds(void);
```

Returns the cached UNIX time in microseconds from `server.ustime`. This value is updated in the server cron job and before executing each command. It does not make a system call, so it is very fast.

Use the cached variant for complex call stacks where consistency matters more than precision - for example, when a command triggers a keyspace notification, which triggers a module callback, which calls `ValkeyModule_Call`. All these callbacks see the same timestamp.

Timing an operation:

```c
uint64_t start = ValkeyModule_MonotonicMicroseconds();
/* ... perform work ... */
uint64_t elapsed = ValkeyModule_MonotonicMicroseconds() - start;
ValkeyModule_Log(ctx, "verbose",
    "Operation took %llu microseconds", (unsigned long long)elapsed);
```

Source: `src/module.c` (lines 2448-2471)

## Database Selection

See [../commands/key-generic.md](../commands/key-generic.md) for `ValkeyModule_GetSelectedDb`, `ValkeyModule_SelectDb`, `ValkeyModule_DbSize`, and `ValkeyModule_RandomKey` - database selection and inspection APIs used alongside key operations.

## Random Bytes

```c
void ValkeyModule_GetRandomBytes(unsigned char *dst, size_t len);
```

Fills `dst` with `len` random bytes using SHA1 in counter mode, seeded from `/dev/urandom`. This is fast and suitable for generating many bytes without impacting the OS entropy pool. Not thread-safe.

```c
void ValkeyModule_GetRandomHexChars(char *dst, size_t len);
```

Same as `GetRandomBytes` but fills the buffer with random hexadecimal characters from the charset `[0-9a-f]`.

Source: `src/module.c` (lines 11047-11060)

Use cases include generating unique IDs, session tokens, or nonces:

```c
char id[33];
ValkeyModule_GetRandomHexChars(id, 32);
id[32] = '\0';
/* id is now a 32-character hex string like "a3f2b1..." */
```

## WrongArity

See [../commands/reply-building.md](../commands/reply-building.md) for `ValkeyModule_WrongArity` - sends an arity error reply from command handlers.

## Feature Detection

Several `*All()` functions return bitmasks of all supported flags for the running server version. These enable forward-compatible modules that can check for features at runtime.

For `GetContextFlagsAll`, see [context.md](context.md). For `GetModuleOptionsAll`, see [module-options.md](module-options.md). The remaining feature detection functions are:

```c
int ValkeyModule_GetKeyspaceNotificationFlagsAll(void);
```

Returns all supported keyspace notification flags. Value equals `_VALKEYMODULE_NOTIFY_NEXT - 1`.

```c
int ValkeyModule_GetTypeMethodVersion(void);
```

Returns the current runtime value of `VALKEYMODULE_TYPE_METHOD_VERSION`. Use when calling `ValkeyModule_CreateDataType` to know which fields of `ValkeyModuleTypeMethods` are supported.

Source: `src/module.c` (lines 14059-14124)
