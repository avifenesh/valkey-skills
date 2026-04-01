# Task: Add BF.COUNT Command to valkey-bloom

## Overview

Add a new `BF.COUNT` command to the valkey-bloom module that returns the approximate number of items that have been added to a bloom filter. This value is the sum of `num_items` across all sub-filters in the `BloomObject`.

Note: `BF.COUNT` is different from `BF.CARD`. Read the existing source code carefully to understand what `BF.CARD` returns and how it works before implementing `BF.COUNT`.

## Source Code

The valkey-bloom source is in `valkey-bloom/` (this workspace).

Key files:
- `src/lib.rs` - Module entry point, command registration
- `src/bloom/command_handler.rs` - Command implementations
- `src/bloom/utils.rs` - BloomObject and BloomFilter data structures
- `src/commands/` - Command metadata JSON files

## Requirements

1. **Command registration**: Register `BF.COUNT` in `src/lib.rs` with `"readonly fast"` flags, key spec `1, 1, 1`, and command tips `"fast read bloom"`
2. **Arity**: Exactly 2 (command name + key), same pattern as `BF.CARD`
3. **Return value**: Integer - sum of `num_items` across all sub-filters
4. **Non-existent key**: Return `0`
5. **Wrong type**: Return `WRONGTYPE` error when the key holds a non-bloom value
6. **ACL category**: `bloom`
7. **Unit test**: Write a Rust test covering:
   - Basic count after adding items
   - Count on a non-existent key returns 0
   - Count after scaling (enough items to trigger a new sub-filter)
8. **Command metadata**: Create `src/commands/bf.count.json` following the format of `src/commands/bf.card.json`

## Build

```
cargo build --release
```

## Constraints

- Do not modify `Cargo.toml` dependencies
- Follow the existing code patterns and style in the codebase
- Work entirely within the `valkey-bloom/` directory
