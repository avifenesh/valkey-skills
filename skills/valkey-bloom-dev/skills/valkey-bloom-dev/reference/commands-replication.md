# Deterministic Replication Strategy

Use when understanding how bloom objects replicate to replicas, why creation uses BF.INSERT with SEED/TIGHTENING, how size limits are bypassed on replicas, or how keyspace notifications fire.

Source: `src/bloom/command_handler.rs` (replicate_and_notify_events, ReplicateArgs), `src/wrapper/mod.rs` (must_obey_client)

## Contents

- Overview (line 23)
- Three Replication Cases (line 29)
- Reserve Replication (line 42)
- Add-Only Replication (line 71)
- No-Op Case (line 83)
- ReplicateArgs Structure (line 93)
- must_obey_client (line 110)
- Size Limit Bypass on Replicas (line 133)
- Keyspace Notifications (line 151)
- Replication in Each Command (line 173)

---

## Overview

The valkey-bloom module uses deterministic replication rather than verbatim replication for object creation. When a primary creates a bloom object, it must ensure the replica creates an identical object - same capacity, fp_rate, tightening_ratio, expansion, and critically the same hash seed. Without the seed, the replica's bloom filter would produce different hash results and diverge.

All mutative commands call `replicate_and_notify_events` after their operation completes. This function handles both replication to replicas and keyspace event notifications.

## Three Replication Cases

The `replicate_and_notify_events` function receives two boolean flags:

- `add_operation: bool` - true when at least one item was successfully added
- `reserve_operation: bool` - true when a new bloom object was created

These flags produce three distinct replication behaviors:

1. **Reserve (creation)**: `reserve_operation == true` - replicates as a synthetic `BF.INSERT`
2. **Add-only (no creation)**: `reserve_operation == false && add_operation == true` - replicates verbatim
3. **No-op**: both false - no replication at all

## Reserve Replication

When `reserve_operation` is true, the function constructs a synthetic `BF.INSERT` command with every property needed to recreate the bloom object identically:

```
BF.INSERT <key> CAPACITY <cap> ERROR <fp> TIGHTENING <ratio> SEED <32bytes>
    [EXPANSION <exp> | NONSCALING] [ITEMS <item1> <item2> ...]
```

The construction in code:

```rust
let mut cmd = vec![
    key_name,
    &capacity_str, &capacity_val,    // CAPACITY <cap>
    &fp_rate_str, &fp_rate_val,      // ERROR <fp>
    &tightening_str, &tightening_val, // TIGHTENING <ratio>
    &seed_str, &seed_val,            // SEED <32bytes>
];
```

**Expansion handling**: If `expansion == 0` (non-scaling), appends `NONSCALING`. Otherwise appends `EXPANSION <value>`.

**Items**: If items were provided (BF.ADD or BF.INSERT with items), appends `ITEMS` followed by the item arguments. For BF.RESERVE, items is empty and the ITEMS keyword is omitted entirely.

**Why BF.INSERT**: BF.INSERT is the only command that accepts all of CAPACITY, ERROR, TIGHTENING, SEED, EXPANSION, NONSCALING, and ITEMS. BF.RESERVE cannot carry SEED or TIGHTENING. By funneling all creation through BF.INSERT, the replication path is unified.

The call to `ctx.replicate("BF.INSERT", cmd.as_slice())` sends this synthetic command to replicas and the AOF.

## Add-Only Replication

When `reserve_operation` is false and `add_operation` is true, the command is replicated verbatim:

```rust
} else if add_operation {
    ctx.replicate_verbatim();
}
```

This covers cases where items are added to an existing bloom object. Since the object already exists on the replica (created by a prior reserve replication), the original command (BF.ADD, BF.MADD, or BF.INSERT) can be replayed as-is.

## No-Op Case

When both flags are false, no replication occurs. This happens when:

- BF.ADD/BF.MADD adds an item that already exists (duplicate) - `add_succeeded` stays false
- BF.INSERT with no items on an existing key
- BF.INSERT where all items were duplicates on an existing key

No replication is needed because nothing changed.

## ReplicateArgs Structure

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

Populated from the **bloom object's actual properties**, not the command arguments. The distinction matters because BF.ADD and BF.MADD do not accept these parameters as arguments - they read them from the created bloom object. For BF.INSERT on an existing object, the object's original properties are used, not the command's override arguments.

The `items` field is a slice of the original input arguments starting at the item index position, so the exact user-supplied items are forwarded to replicas.

## must_obey_client

The `must_obey_client` function in `src/wrapper/mod.rs` determines whether the current command is arriving from a primary or AOF replay and should not be rejected:

**Valkey 8.1+** (default, no feature flag):

```rust
let ctx_raw = ctx.get_raw() as *mut valkey_module::ValkeyModuleCtx;
let status = unsafe { valkey_module::raw::ValkeyModule_MustObeyClient.unwrap()(ctx_raw) };
```

Uses the `ValkeyModule_MustObeyClient` API from the `valkey_module::raw` bindings. Returns 1 when the command comes from the primary or AOF client. Panics on unexpected return values.

**Valkey 8.0** (feature `valkey_8_0`):

```rust
ctx.get_flags().contains(valkey_module::ContextFlags::REPLICATED)
```

Falls back to checking `ContextFlags::REPLICATED` via the `GetContextFlags` API. A best-effort approximation since the flag-based approach is less precise than the dedicated API.

The feature flag is compile-time: `cargo build --features valkey_8_0`. Without the flag, the 8.1+ path is used.

## Size Limit Bypass on Replicas

Every mutative command handler checks:

```rust
let validate_size_limit = !must_obey_client(ctx);
```

When `must_obey_client` returns true (replica receiving from primary, or AOF replay), `validate_size_limit` is false. This means:

- `BloomObject::new_reserved` skips `validate_size_before_create`
- `BloomObject::add_item` skips `validate_size_before_scaling`
- `BloomObject::decode_object` (BF.LOAD path) skips memory size validation

Replicas never reject operations that the primary accepted. If the primary's `bloom-memory-usage-limit` allowed a bloom object, the replica must accept it even if the replica has a different (lower) memory limit configured.

The size limit is enforced only on user-initiated commands on the primary node.

## Keyspace Notifications

Two events are published after replication, defined as constants in `utils.rs`:

```rust
pub const ADD_EVENT: &str = "bloom.add";
pub const RESERVE_EVENT: &str = "bloom.reserve";
```

Notification logic in `replicate_and_notify_events`:

```rust
if add_operation {
    ctx.notify_keyspace_event(NotifyEvent::GENERIC, "bloom.add", key_name);
}
if reserve_operation {
    ctx.notify_keyspace_event(NotifyEvent::GENERIC, "bloom.reserve", key_name);
}
```

Both events can fire in the same call - when BF.ADD or BF.INSERT creates a new object and adds items, both `bloom.reserve` and `bloom.add` are emitted. The events use `NotifyEvent::GENERIC` category. Keyspace notifications fire independently of the replication path - both checks run regardless of which replication branch was taken.

## Replication in Each Command

| Command | Creation | Add-Only | Notes |
|---------|----------|----------|-------|
| BF.ADD | BF.INSERT with full props + items | Verbatim | Auto-creates if key missing |
| BF.MADD | BF.INSERT with full props + items | Verbatim | Auto-creates if key missing |
| BF.RESERVE | BF.INSERT with full props, no items | Never | Creation-only, no items to add |
| BF.INSERT | BF.INSERT with full props + items | Verbatim | Explicit creation or add |
| BF.LOAD | BF.INSERT with full props | Never | AOF rewrite path, creation-only |

All creation paths use the same `replicate_and_notify_events` function. The replicated BF.INSERT always includes SEED and TIGHTENING, ensuring the replica's bloom object is bit-for-bit identical in hash behavior.