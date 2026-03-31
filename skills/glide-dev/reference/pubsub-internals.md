# PubSub Synchronizer Internals

Use when working on GLIDE's PubSub subscription management, debugging subscription state, or understanding the reconciliation loop.

## Architecture

The `GlidePubSubSynchronizer` (in `glide-core/src/pubsub/synchronizer.rs`) implements an observer pattern:

- `desired_subscriptions` (RwLock<PubSubSubscriptionInfo>) - what the user wants
- `current_subscriptions_by_address` (RwLock<HashMap<String, PubSubSubscriptionInfo>>) - what's actually subscribed, tracked per server address

A background reconciliation task runs at a configurable interval (default: 3 seconds) to align current with desired.

## Subscription Kinds

```rust
// Cluster supports all three
const CLUSTER_SUBSCRIPTION_KINDS: &[PubSubSubscriptionKind] = &[
    PubSubSubscriptionKind::Exact,    // SUBSCRIBE
    PubSubSubscriptionKind::Pattern,  // PSUBSCRIBE
    PubSubSubscriptionKind::Sharded,  // SSUBSCRIBE
];

// Standalone only supports exact and pattern
const STANDALONE_SUBSCRIPTION_KINDS: &[PubSubSubscriptionKind] = &[
    PubSubSubscriptionKind::Exact,
    PubSubSubscriptionKind::Pattern,
];
```

## Reconciliation Loop

The `SyncDiff` struct avoids recomputation:
```rust
struct SyncDiff {
    is_synchronized: bool,
    to_subscribe: PubSubSubscriptionInfo,       // channels we want but don't have
    to_unsubscribe_by_address: HashMap<String, PubSubSubscriptionInfo>,  // channels we have but don't want
}
```

### Triggers
1. **User API call** - `subscribe()` / `unsubscribe()` modifies `desired_subscriptions` and notifies the reconciliation task
2. **Server push notification** - updates `current_subscriptions_by_address`
3. **Timer** - reconciliation runs every `reconciliation_interval` (default 3s)
4. **Topology change** - cluster slot migration triggers resubscription on new nodes

### Topology Change Handling

When cluster topology changes (slot migration, node failure):
1. Node disconnection clears that address from `current_subscriptions_by_address`
2. Migrated subscriptions are queued in `pending_unsubscribes` for the old node
3. Reconciliation loop subscribes on the new correct node
4. For removed nodes, all subscriptions are cleared and resubscribed elsewhere

## Key Design Decisions

- `Weak<TokioRwLock<ClientWrapper>>` for the client reference - avoids circular refs and memory leaks
- `OnceCell` for late initialization - the client is set after construction
- `Notify` primitives for efficient wake-up - no polling overhead
- `PubSubCommandApplier` trait - abstracts command execution for testability (see `mock.rs`)
- Separate `desired` vs `current` state prevents subscription drift

## Files

| File | Purpose |
|------|---------|
| `glide-core/src/pubsub/mod.rs` | Module definition, re-exports |
| `glide-core/src/pubsub/synchronizer.rs` | GlidePubSubSynchronizer implementation |
| `glide-core/src/pubsub/mock.rs` | Mock implementation for testing |

## Node.js Binding Path

For the Node.js client, PubSub flows through:
1. `node/src/BaseClient.ts` - `subscribe()`, `psubscribe()`, `unsubscribe()` methods
2. `node/rust-client/src/lib.rs` - NAPI bindings call into Rust core
3. `glide-core/src/pubsub/synchronizer.rs` - reconciliation and state management
4. Messages arrive via push notifications and are routed back through NAPI to JS callbacks
