# Deterministic replication

Use when reasoning about how primary sends bloom state to replicas, SEED/TIGHTENING as replication-internal args, size limit bypass, or keyspace notifications.

Source: `src/bloom/command_handler.rs` (`replicate_and_notify_events`, `ReplicateArgs`), `src/wrapper/mod.rs` (`must_obey_client`).

## Why not verbatim

Verbatim BF.ADD would diverge on replicas - each would pick its own random seed. Primary must ship the exact seed plus capacity / fp_rate / tightening_ratio / expansion so the replica's bloom is bit-for-bit identical in hash behavior.

Every mutative command calls `replicate_and_notify_events(add_operation, reserve_operation, ...)` after its work. That function dispatches replication and keyspace events.

## Three cases

| `reserve_operation` | `add_operation` | Action |
|:-:|:-:|---|
| true | * | synthetic `BF.INSERT` with full object properties (see below) |
| false | true | `ctx.replicate_verbatim()` - replays the original command |
| false | false | no-op (pure duplicate add, or empty INSERT on existing key) |

## Synthetic BF.INSERT form

```
BF.INSERT <key> CAPACITY <cap> ERROR <fp> TIGHTENING <ratio> SEED <32 bytes>
          [EXPANSION <exp> | NONSCALING] [ITEMS <item> ...]
```

- `expansion == 0` appends `NONSCALING`, else `EXPANSION <value>`.
- `ITEMS` present only if items were supplied (BF.RESERVE replication omits the entire ITEMS clause).

Why BF.INSERT: it's the only command that accepts CAPACITY + ERROR + TIGHTENING + SEED + EXPANSION + NONSCALING + ITEMS. BF.RESERVE can't carry SEED / TIGHTENING. Funneling all creation through BF.INSERT unifies the replication path.

Called via `ctx.replicate("BF.INSERT", cmd.as_slice())` - also goes to AOF when AOF and replication are both enabled. (Note: AOF **rewrite** uses the different BF.LOAD path, see `architecture-persistence.md`.)

## `ReplicateArgs`

```rust
struct ReplicateArgs<'a> {
    capacity: i64,
    expansion: u32,
    fp_rate: f64,
    tightening_ratio: f64,
    seed: [u8; 32],
    items: &'a [ValkeyString],
}
```

Populated from the **actual bloom object**, not the command's input args. Matters because:

- BF.ADD / BF.MADD accept no property args - properties are read from the newly created (or existing) bloom.
- BF.INSERT on an existing object ignores its own CAPACITY/ERROR/... overrides for replication and uses the object's creation-time values.

## `must_obey_client`

In `src/wrapper/mod.rs`, detects whether the current command came from primary-to-replica replication or AOF replay. Two impls gated by feature flag:

| Build | Impl |
|-------|------|
| default (Valkey 8.1+) | `ValkeyModule_MustObeyClient` via `valkey_module::raw` - returns 1 when command is from primary / AOF client |
| `--features valkey_8_0` | `ctx.get_flags().contains(ContextFlags::REPLICATED)` - best-effort fallback using `GetContextFlags` (less precise) |

Compile-time - no runtime toggle.

## Size limit bypass on replicas

Every mutative handler:

```rust
let validate_size_limit = !must_obey_client(ctx);
```

When true (replica / AOF replay), passed as `false` to:

- `BloomObject::new_reserved` - skips `validate_size_before_create`.
- `BloomObject::add_item` - skips `validate_size_before_scaling`.
- `BloomObject::decode_object` (BF.LOAD) - skips total-size check.

Replicas never reject what the primary accepted. A lower `bloom-memory-usage-limit` on a replica is irrelevant to replication.

## Keyspace notifications

```rust
pub const ADD_EVENT:     &str = "bloom.add";
pub const RESERVE_EVENT: &str = "bloom.reserve";
```

Fired in `replicate_and_notify_events`:

- `add_operation` true -> `notify_keyspace_event(GENERIC, "bloom.add", key)`.
- `reserve_operation` true -> `notify_keyspace_event(GENERIC, "bloom.reserve", key)`.

Both can fire in the same call (BF.ADD / BF.INSERT that creates and adds). Independent of the replication branch taken.

## Per-command replication summary

| Command | Creation | Add-only | Notes |
|---------|----------|----------|-------|
| BF.ADD | synthetic BF.INSERT + items | verbatim | auto-create on missing key |
| BF.MADD | synthetic BF.INSERT + items | verbatim | auto-create on missing key |
| BF.RESERVE | synthetic BF.INSERT (no items) | never | creation-only |
| BF.INSERT | synthetic BF.INSERT + items | verbatim | explicit flow |
| BF.LOAD | synthetic BF.INSERT + data-as-item | never | AOF-rewrite-fed command; replica rebuilds via BF.INSERT, not BF.LOAD |
