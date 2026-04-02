# Add BF.DUMP Command to valkey-bloom

Add a new `BF.DUMP` command to the valkey-bloom module that serializes a bloom filter to its raw bytes for backup and migration purposes.

## Command Specification

**Syntax**: `BF.DUMP key`

**Behavior**:
- Returns the serialized bytes of the bloom filter stored at `key`
- Returns nil (null bulk string) when the key does not exist
- Returns a WRONGTYPE error when the key holds a value that is not a bloom filter
- The command is **readonly** - it does not modify any data

**Complexity**: O(N) where N is the size of the serialized bloom filter.

## Requirements

1. **Command registration** - register `BF.DUMP` in the module with appropriate flags (readonly, not deny-oom since it only reads)
2. **Command metadata** - create the JSON metadata file for `COMMAND DOCS` support
3. **Handler implementation** - implement the command handler following the existing codebase patterns
4. **Tests** - add tests covering the command's behavior (success case, nil on missing key, WRONGTYPE on wrong type)
5. **Build** - the code must compile cleanly with `cargo build --release`

## Workspace

The valkey-bloom source is in the `valkey-bloom/` subdirectory. Work only within that directory. Study the existing command implementations to understand the patterns used in this codebase before writing code.
