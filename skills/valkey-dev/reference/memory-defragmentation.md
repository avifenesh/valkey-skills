# Active Defragmentation

Use when you need to understand how Valkey reduces external memory fragmentation at runtime.

Standard jemalloc-based active defrag - relocates live objects from sparse slabs to denser ones. Stage-based scan over all data structures with time-bounded execution and adaptive CPU budget.

## Valkey-Specific Changes

- **`active-defrag-cycle-us` config**: Base cycle duration in microseconds (default 500). This is a Valkey-specific parameter not present in Redis. Controls the granularity of defrag time slices.
- **Independent timer event**: Defrag runs as its own timer event, not inside `serverCron`. Adaptive duty cycle: `D = P * W / (100 - P)` where P = target CPU%, W = wait time.
- **kvstore-aware scanning**: Defrag stages scan `db->keys`, `db->expires`, and `db->keys_with_volatile_items` kvstores.
- **Hash field TTL defrag**: Scans `keys_with_volatile_items` kvstore for hashes with per-field TTLs.

Source: `src/defrag.c`, `src/allocator_defrag.c`
