# Lua Scripting

Use when you need atomic multi-step logic on the server side - conditional updates, read-modify-write patterns, or custom commands that cannot be expressed with standard Valkey commands. For persistent server-side functions, see the Valkey Functions section below (requires Valkey 7.0+).

GLIDE provides a `Script` class that handles Lua script caching automatically. The script body is stored in a global container with SHA1 hashing and reference counting. On first invocation, the client sends EVALSHA; if the server does not recognize the hash, GLIDE falls back to EVAL which loads the script. Subsequent calls use EVALSHA directly.

## How Script Caching Works

The Rust core (`scripts_container.rs`) manages a global `HashMap<String, ScriptEntry>` where:

- `add_script(bytes)` computes a SHA1 hash of the script body and stores it with a reference count
- `get_script(hash)` returns the script bytes by hash
- `remove_script(hash)` decrements the reference count; when it reaches 0, the entry is removed from memory

Multiple `Script` objects with identical code share the same entry via reference counting, avoiding duplicate storage.

## Python

```python
from glide import Script

# Create a script object - script bytes are hashed and stored
script = Script("return {KEYS[1], ARGV[1]}")

# Execute - first call uses EVALSHA (falls back to EVAL if needed)
result = await client.invoke_script(script, keys=["mykey"], args=["myvalue"])
# result: [b'mykey', b'myvalue']
```

### Script with SET and GET

```python
script = Script("""
    local key = KEYS[1]
    local value = ARGV[1]
    redis.call('SET', key, value)
    return redis.call('GET', key)
""")
result = await client.invoke_script(script, keys=["mykey"], args=["hello"])
# result: b'hello'
```

### Simple return

```python
script = Script("return 'Hello'")
result = await client.invoke_script(script)
# result: b'Hello'
```

## Java

```java
import glide.api.models.Script;
import glide.api.models.commands.ScriptOptions;

// Script implements AutoCloseable - use try-with-resources
try (Script luaScript = new Script("return {KEYS[1], ARGV[1]}", false)) {
    ScriptOptions options = ScriptOptions.builder()
        .key("mykey")
        .arg("myvalue")
        .build();
    Object[] result = (Object[]) client.invokeScript(luaScript, options).get();
    // result: ["mykey", "myvalue"]
}
```

The Java `Script` class:
- Constructor takes `(code, binaryOutput)` - `binaryOutput` indicates if the result can contain binary data
- Implements `AutoCloseable` - calling `close()` drops the script from the container via `ScriptResolver.dropScript(hash)`
- Stores the SHA1 hash as `getHash()`

Related option classes:
- `ScriptOptions` - keys and args as `String`
- `ScriptOptionsGlideString` - keys and args as `GlideString` (binary-safe)
- `ScriptArgOptions` - args only (no keys)
- `ScriptArgOptionsGlideString` - args only as `GlideString`

## Node.js

```javascript
import { Script } from "@valkey/valkey-glide";

const script = new Script("return { KEYS[1], ARGV[1] }");
const result = await client.invokeScript(script, {
    keys: ["mykey"],
    args: ["myvalue"],
});
// result: ["mykey", "myvalue"]
```

For cluster clients, use `invokeScriptWithRoute` to control routing:

```javascript
const result = await clusterClient.invokeScriptWithRoute(script, {
    args: ["bar"],
});
```

## Go

```go
import "github.com/valkey-io/valkey-glide/go/v2/options"

// Create script
script := options.NewScript("return 'Hello'")
defer script.Close()

result, err := client.InvokeScript(ctx, *script)
// result: "Hello"

// With keys and args
script2 := options.NewScript(`
    local key = KEYS[1]
    local value = ARGV[1]
    redis.call('SET', key, value)
    return redis.call('GET', key)
`)
defer script2.Close()

result, err := client.InvokeScriptWithOptions(ctx, *script2, options.ScriptOptions{
    Keys: []string{"mykey"},
    Args: []string{"myvalue"},
})
```

The Go `Script` struct:
- `NewScript(code)` creates a new script, stores the bytes, and returns a `*Script` with the SHA1 hash
- `Close()` drops the script from the container (thread-safe via mutex)
- `GetHash()` returns the SHA1 hash string

Related option types:
- `ScriptOptions` - contains `Keys` and `Args` string slices
- `ScriptArgOptions` - contains `Args` only
- `NewScriptOptions()` / `NewScriptArgOptions()` - factory functions with empty defaults

## Cluster Mode Routing

In cluster mode, Lua scripts that access keys are routed based on the hash slot of the first key in `KEYS`. All keys passed to a script must belong to the same hash slot - this is a Valkey server requirement, not a GLIDE limitation.

For scripts that do not access any keys (keyless scripts), GLIDE routes them to a random node. Use routing options to target a specific node if needed.

## Script Lifecycle

1. Application creates `Script("lua code")` - GLIDE computes SHA1 and stores the bytes in the global container
2. Application calls `invoke_script(script, keys, args)` - GLIDE sends EVALSHA with the hash
3. If the server returns NOSCRIPT (script not cached on this node), GLIDE falls back to EVAL
4. When the `Script` object is closed/garbage-collected, the reference count decrements
5. When reference count reaches 0, the script bytes are removed from the client-side container

## Limitations

- `invoke_script` is NOT supported in batch operations (pipelines/transactions). Use `custom_command(["EVAL", ...])` within batches instead.
- SCAN family commands within Lua scripts are not traced by OpenTelemetry
- All keys accessed in a script must belong to the same hash slot in cluster mode
- Script execution is atomic on the server - long-running scripts block other commands
- Scripts that perform write operations cannot be killed - they must complete or timeout. Only read-only scripts can be terminated with SCRIPT KILL.

---

## Valkey Functions (7.0+)

Valkey Functions are a server-side scripting mechanism introduced in Valkey 7.0 that replace ad-hoc Lua scripts with named, persistent library-based functions. Unlike `EVAL`/`EVALSHA` scripts, functions are stored on the server, survive restarts (when persisted), and are organized into libraries.

### Core Concepts

A **library** is a named unit of code that contains one or more **functions**. Libraries are loaded onto the server with `FUNCTION LOAD` and their functions are invoked by name with `FCALL` or `FCALL_RO`. The server manages the lifecycle - functions persist across connections and can be listed, deleted, dumped, and restored.

### GLIDE Request Types

All function commands are verified in the Rust core (`request_type.rs`):

| RequestType | Valkey Command | ID |
|-------------|---------------|----|
| `FunctionLoad` | `FUNCTION LOAD` | 1012 |
| `FunctionList` | `FUNCTION LIST` | 1011 |
| `FunctionDelete` | `FUNCTION DELETE` | 1007 |
| `FunctionDump` | `FUNCTION DUMP` | 1008 |
| `FunctionFlush` | `FUNCTION FLUSH` | 1009 |
| `FunctionRestore` | `FUNCTION RESTORE` | 1013 |
| `FunctionStats` | `FUNCTION STATS` | 1014 |
| `FunctionKill` | `FUNCTION KILL` | 1010 |
| `FCall` | `FCALL` | 1005 |
| `FCallReadOnly` | `FCALL_RO` | 1006 |

### Method Names by Language

| Operation | Python | Java | Node.js | Go |
|-----------|--------|------|---------|----|
| Load library | `function_load()` | `functionLoad()` | `functionLoad()` | `FunctionLoad()` |
| List libraries | `function_list()` | `functionList()` | `functionList()` | `FunctionList()` |
| Delete library | `function_delete()` | `functionDelete()` | `functionDelete()` | `FunctionDelete()` |
| Dump all | `function_dump()` | `functionDump()` | `functionDump()` | `FunctionDump()` |
| Flush all | `function_flush()` | `functionFlush()` | `functionFlush()` | `FunctionFlush()` |
| Restore from dump | `function_restore()` | `functionRestore()` | `functionRestore()` | `FunctionRestore()` |
| Get stats | `function_stats()` | `functionStats()` | `functionStats()` | `FunctionStats()` |
| Kill running | `function_kill()` | `functionKill()` | `functionKill()` | `FunctionKill()` |
| Call function | `fcall()` | `fcall()` | `fcall()` | `FCall()` |
| Call read-only | `fcall_ro()` | `fcallReadOnly()` | `fcallReadOnly()` | `FCallReadOnly()` |

In cluster mode, Python and Node.js provide additional routing variants. Python has `fcall_route()` and `fcall_ro_route()` on the cluster client. Go has `FCallWithRoute()` and `FCallReadOnlyWithRoute()` on the cluster client.

### Python Example

```python
from glide import GlideClient

# Library code must start with a shebang declaring the engine and library name
code = "#!lua name=mylib \n redis.register_function('myfunc', function(keys, args) return args[1] end)"

# Load the library (replace=True overwrites if it already exists)
library_name = await client.function_load(code, replace=True)
# library_name: b"mylib"

# Call the function with arguments
result = await client.fcall("myfunc", keys=["mykey"], arguments=["hello"])
# result: b"hello"

# Call a read-only function (safe for replicas)
result = await client.fcall_ro("myfunc", arguments=["world"])
# result: b"world"

# List all loaded libraries
libraries = await client.function_list()
# Returns list of dicts with library_name, engine, functions

# List with code and pattern filter
libraries = await client.function_list(library_name_pattern="mylib*", with_code=True)

# Delete a specific library
await client.function_delete("mylib")

# Dump all libraries (returns serialized bytes)
dump = await client.function_dump()

# Restore libraries from a dump
await client.function_restore(dump)

# Flush all libraries
await client.function_flush()

# Get function execution statistics
stats = await client.function_stats()
```

### Node.js Example

```javascript
import { GlideClient } from "@valkey/valkey-glide";

const code =
    '#!lua name=mylib \\n redis.register_function("myfunc", function(keys, args) return args[1] end)';

// Load the library
const libraryName = await client.functionLoad(code, { replace: true });
// libraryName: "mylib"

// Call the function
const result = await client.fcall("myfunc", ["mykey"], ["hello"]);

// Call read-only variant
const roResult = await client.fcallReadOnly("myfunc", [], ["world"]);

// List loaded libraries
const libraries = await client.functionList();

// Delete a library
await client.functionDelete("mylib");

// Dump and restore
const dump = await client.functionDump();
await client.functionRestore(dump);

// Flush all
await client.functionFlush();
```

### Go Example

```go
// Load the library
code := "#!lua name=mylib \n redis.register_function('myfunc', function(keys, args) return args[1] end)"
libraryName, err := client.FunctionLoad(ctx, code, true)
// libraryName: "mylib"

// Call the function with keys and args
result, err := client.FCallWithKeysAndArgs(ctx, "myfunc", []string{"mykey"}, []string{"hello"})

// Read-only call
result, err = client.FCallReadOnly(ctx, "myfunc")

// List, delete, dump, restore, flush
libraries, err := client.FunctionList(ctx)
err = client.FunctionDelete(ctx, "mylib")
dump, err := client.FunctionDump(ctx)
err = client.FunctionRestore(ctx, dump)
_, err = client.FunctionFlush(ctx)
```

### Functions vs Scripts: When to Use Each

| Aspect | Lua Scripts (`invoke_script`) | Functions (`fcall`) |
|--------|-------------------------------|---------------------|
| Persistence | Client-side only; must re-send after server restart | Server-side; survive restarts when persisted |
| Naming | Addressed by SHA1 hash | Addressed by human-readable function name |
| Organization | Standalone script blobs | Grouped into named libraries |
| Deployment | Implicit via EVAL/EVALSHA fallback | Explicit via FUNCTION LOAD |
| Versioning | No built-in versioning | Library-level replace semantics |
| Migration | Must be sent to each node | FUNCTION DUMP/RESTORE for cross-server migration |
| Minimum version | All versions | Valkey 7.0+ |

**Use scripts** when you have simple, short-lived logic and want zero server-side setup. The GLIDE `Script` class handles caching transparently.

**Use functions** when you need named, reusable server-side logic that persists across connections and restarts. Functions are the recommended approach for production workloads on Valkey 7.0+ - they provide better manageability, explicit deployment, and library-level organization.

### Read-Only Functions

GLIDE implements `fcall_ro` / `fcallReadOnly` / `FCallReadOnly` for read-only functions, enabling routing to replicas for read scaling:

```python
# Python - read-only function call
result = await client.fcall_ro("get_value", keys=["mykey"])

# With routing in cluster mode
from glide import AllPrimaries
result = await client.fcall_ro_route("get_value", AllPrimaries())
```

Read-only functions are guaranteed not to modify data, allowing GLIDE to safely route them to replica nodes when using PreferReplica or AZ Affinity read strategies. See [AZ Affinity](az-affinity.md) for configuring read routing.

## Related Features

- [Batching](batching.md) - `invoke_script` is NOT supported in batches; use `custom_command(["EVAL", ...])` within batches instead
- [OpenTelemetry](opentelemetry.md) - EVAL/EVALSHA commands are not included in OTel tracing
- [AZ Affinity](az-affinity.md) - read-only functions (`fcall_ro`) can be routed to same-zone replicas
