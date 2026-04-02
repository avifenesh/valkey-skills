# Build a TOPK Valkey Module in Rust

Build a Valkey module using the `valkey-module` Rust crate that implements a probabilistic top-K frequent items tracker.

## Commands

- `TOPK.ADD key item [count]` - Track an item occurrence. Default count is 1. Returns the new count for that item.
- `TOPK.LIST key [n]` - Return the top N items sorted by frequency (default: all). Returns alternating item/count pairs.
- `TOPK.COUNT key item` - Return the count for a specific item. Returns 0 if not tracked.
- `TOPK.RESET key` - Reset all counts to zero. Returns OK.

## Requirements

- The module must load into valkey-server
- Data must survive restart (implement RDB save/load)
- Write commands must replicate correctly to replicas
- The Cargo project is set up with the `valkey-module` dependency

Implement everything in `src/lib.rs`.
