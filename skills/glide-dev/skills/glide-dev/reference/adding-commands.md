# Adding New Commands to GLIDE

Use when implementing a new Valkey command across the GLIDE client.

## Steps

### 1. Add to RequestType enum (`glide-core/src/request_type.rs`)

```rust
// Add variant with next available number in the appropriate section
MyNewCommand = NNN,
```

Commands are grouped by category (Bitmap 1xx, Cluster 2xx, Connection 3xx, etc.).

### 2. Add protobuf mapping (`glide-core/src/request_type.rs`)

In the `From<ProtobufRequestType>` impl, map the protobuf variant to the Rust enum.

### 3. Implement command construction

In `request_type.rs`, add the `get_command()` match arm that builds the redis `Cmd`:

```rust
RequestType::MyNewCommand => {
    cmd("MYNEWCOMMAND")
}
```

### 4. Add to each language wrapper

**Node.js** (`node/src/Commands.ts`):
```typescript
export function createMyNewCommand(args: ...): redis_request.Command {
    return createCommand(RequestType.MyNewCommand, [...args]);
}
```

Then in `node/src/BaseClient.ts`, add the public method:
```typescript
public async myNewCommand(...): Promise<ReturnType> {
    return this.createWritePromise(createMyNewCommand(...));
}
```

**Python async** (`python/glide-async/python/glide/async_commands/`):
Add the command method to `CoreCommands` (or `StandaloneCommands`/`ClusterCommands` if mode-specific).

**Python sync** (`python/glide-sync/glide_sync/sync_commands/`):
Add the matching sync method to the corresponding command group.

**Java** (`java/client/src/main/java/glide/api/commands/`):
Add to the appropriate command interface and implement in `BaseClient`.

**Go** (`go/internal/interfaces/`):
Add to the appropriate interface and implement in `base_client.go`.

### 5. Add tests

Each language needs tests:
- Unit test for command construction
- Integration test against a real Valkey server
- Cluster mode test if routing matters

Test locations:
- Node.js: `node/tests/`
- Python: `python/tests/`
- Java: `java/client/src/test/java/glide/`
- Go: `go/` (unit tests co-located with source), `go/integTest/` (integration tests)

### 6. Update protobuf definitions

If adding to protobuf (IPC-based languages):
- `glide-core/src/protobuf/command_request.proto` - add to RequestType enum
- Regenerate: protobuf files are auto-generated during build
