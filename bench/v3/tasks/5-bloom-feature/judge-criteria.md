## Task 5: Bloom Feature Addition - Judge Criteria

### Context

The agent was asked to add a `BF.COUNT` command to the valkey-bloom Rust module. This command returns the approximate number of items added to a bloom filter (sum of `num_items` across all sub-filters).

### Evaluation Focus

**Correct integration into existing codebase (30%)**
- Command registered in `src/lib.rs` inside the `valkey_module!` macro's `commands` array
- Handler function wired up correctly with proper signature `fn(ctx: &Context, args: Vec<ValkeyString>) -> ValkeyResult`
- Uses `"readonly fast"` flags and `"fast read bloom"` command tips, matching the pattern of `BF.CARD` and `BF.EXISTS`
- Key spec indices `1, 1, 1` matching other single-key readonly commands

**Rust patterns matching existing code style (25%)**
- Handler follows the same structure as `bloom_filter_card`: parse argc, validate arity, open key readonly, match on value
- Uses `ctx.open_key()` (not `open_key_writable()`) since this is a readonly command
- Error handling matches existing patterns: `ValkeyError::WrongArity`, `ValkeyError::WrongType`
- Returns `ValkeyValue::Integer(0)` for non-existent keys, not an error
- Function placed in `command_handler.rs` with a public function callable from `lib.rs`

**Correct implementation (25%)**
- Returns the sum of `num_items` across all sub-filters (either by calling `cardinality()` or by manually iterating `filters` and summing `num_items`)
- Handles non-existent key (returns 0)
- Handles wrong-type key (returns WRONGTYPE error)
- Correct arity check (exactly 2 args: command + key)

**Test quality (10%)**
- Test exists (Rust unit test, integration test, or Python test)
- Covers basic functionality, edge cases (non-existent key), and ideally scaled filters

**Command metadata (10%)**
- `src/commands/bf.count.json` exists with correct structure
- Matches the format of existing command JSON files
- Contains proper arity (2), ACL categories (READ, FAST, BLOOM), and argument definition

### Red Flags (deduct points)
- Using `open_key_writable` for a readonly command
- Not returning 0 for non-existent keys (returning an error instead)
- Modifying Cargo.toml dependencies
- Adding the command but never registering it in the `valkey_module!` macro
- Creating a separate module or file when the pattern is to add to `command_handler.rs`
