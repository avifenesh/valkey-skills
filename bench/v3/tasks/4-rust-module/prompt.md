Build a COUNTER module for Valkey using the `valkey-module` Rust crate. The module implements three commands:

- **COUNTER.INCR key [amount]** - Increment the counter at `key` by `amount` (default 1). Return the new value as an integer. Create the key with value `amount` if it does not exist.
- **COUNTER.GET key** - Return the current counter value as an integer. Return 0 if the key does not exist.
- **COUNTER.RESET key** - Reset the counter to 0. Return the previous value as an integer. Return 0 if the key did not exist.

Requirements:

1. Use a custom data type registered with `ValkeyType` so the counter value is stored as native module data, not a plain string.
2. Implement RDB save/load callbacks so counter values persist across server restarts.
3. Replicate all write commands (COUNTER.INCR and COUNTER.RESET) to replicas using `replicate_verbatim`.
4. Handle wrong arity and invalid integer arguments with appropriate error replies.
5. The module name must be `counter` and the library name must be `counter_module`.

The workspace already has `Cargo.toml` and an empty `src/lib.rs`. A `docker-compose.yml` is provided with a primary and replica Valkey instance for testing.

Implement the module in `src/lib.rs`. Do not modify `Cargo.toml` or `docker-compose.yml`.
