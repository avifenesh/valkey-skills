## Task 4: Rust COUNTER Module - Judging Criteria

Evaluate the implementation in `src/lib.rs` against these criteria:

### Correct Rust Module API Usage (30%)
- Uses `valkey_module!` macro with proper name, version, allocator, data_types, and commands arrays
- Command handlers accept `&Context` and `Vec<ValkeyString>`, return `ValkeyResult`
- Opens keys with `ctx.open_key()` / `ctx.open_key_writable()` and uses `get_value` / `set_value` with the custom type
- Uses `ValkeyAlloc` as the global allocator
- Returns appropriate `ValkeyValue` variants (Integer, Null) and `ValkeyError` for failures

### Custom Data Type with RDB Callbacks (25%)
- Defines a static `ValkeyType` with a unique 9-character type name
- Implements `rdb_save` callback that writes the counter value using `save_signed` or `save_unsigned`
- Implements `rdb_load` callback that reads the value back in matching order
- Encoding version is consistent between save and load
- The `free` callback properly drops the value

### Replication (15%)
- All write commands (COUNTER.INCR and COUNTER.RESET) call `ctx.replicate_verbatim()` to propagate to replicas
- Read-only COUNTER.GET does not replicate

### Error Handling (15%)
- Returns `ValkeyError::WrongArity` for wrong number of arguments
- Handles non-integer amount argument with a clear error
- Handles missing keys gracefully (GET returns 0, RESET returns 0)
- Does not panic or unwrap without checking

### Code Quality (15%)
- Clean, idiomatic Rust - no unnecessary unsafe blocks
- Reasonable structure (functions separated, types named well)
- No dead code or leftover boilerplate
- Comments where non-obvious logic exists
