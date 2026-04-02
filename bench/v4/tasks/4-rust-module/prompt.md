# Build a TOPK Valkey Module in Rust

Implement a custom Valkey module that provides a top-K frequent items data structure. Use the `valkey-module` Rust crate to build it.

## Module Commands

### TOPK.ADD key item [increment]

Add an item to the top-K tracker. If `increment` is provided, increase the item's count by that amount; otherwise increment by 1. Return the new count for the item as an integer.

### TOPK.LIST key [count]

List the top items sorted by frequency (highest first). If `count` is provided, return at most that many items. Otherwise return all tracked items. Return an array of alternating item-name, count pairs.

### TOPK.COUNT key item

Return the current count for a specific item. Return 0 if the item has not been added.

### TOPK.RESET key

Reset all counts for the key, clearing all tracked items. Return OK.

## Requirements

1. The module name for registration should be `"topk"`.
2. The custom data type name must be exactly 9 characters (this is a Valkey requirement for all custom module data types).
3. The module must support RDB persistence - implement save and load callbacks so data survives a BGSAVE and server restart.
4. All write commands (`TOPK.ADD`, `TOPK.RESET`) must call `replicate_verbatim()` to ensure proper replication to replicas and AOF.
5. The `.so` shared library must load into `valkey-server` via the `--loadmodule` flag.

## Workspace

A Cargo project skeleton is provided with `Cargo.toml` and `src/lib.rs`. The skeleton compiles but the module does nothing yet. Fill in the TODO sections to implement the full module.

Work only within this directory. Do not modify `Cargo.toml`.
