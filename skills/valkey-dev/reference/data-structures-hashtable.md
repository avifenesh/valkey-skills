# Hashtable - Open-Addressing Hash Table (8.1+)

Use when you need the primary key-value store or the backing structure for Hash, Set, and Sorted Set types. This replaced the legacy `dict` starting in Valkey 8.1.

Source: `src/hashtable.c`, `src/hashtable.h`

Valkey-original data structure (designed by Viktor Soderqvist), not present in Redis. Cache-friendly open-addressing hash table with 64-byte cache-line-aligned buckets holding up to 7 entries each.

## Key Properties

- 2 memory accesses per lookup (vs 4 in old dict), ~20-30 bytes per entry (vs ~56-72)
- Secondary hash (h2): highest 8 bits per slot eliminate ~99.6% of false positives without key comparison
- SIMD-accelerated bucket scanning: x86 SSE/AVX and ARM NEON
- Bucket chaining: when 7 slots fill, last slot becomes pointer to child bucket (same 64-byte layout)
- Incremental rehashing with two tables, same pattern as dict
- Resize policies: ALLOW (normal), AVOID (fork/COW), FORBID (child process)
- Incremental find API: `hashtableIncrementalFindInit/Step/GetResult` spreads lookup cost across event loop iterations

## Bucket Layout

```
64-byte cache line: [1-bit chained][7-bit presence][7 x 1-byte h2 hash][7 x 8-byte entry pointer]
```

## Key API

Lifecycle: `hashtableCreate`, `hashtableRelease`, `hashtableEmpty`. Operations: `hashtableFind`, `hashtableAdd`, `hashtableDelete`, `hashtablePop`. Two-phase insert: `hashtableFindPositionForInsert` + `hashtableInsertAtPosition`. Iteration: `hashtableInitIterator` + `hashtableNext`, `hashtableScan`. Random: `hashtableFairRandomEntry`, `hashtableSampleEntries`.

| Aspect | dict (legacy) | hashtable (8.1+) |
|--------|--------------|------------------|
| Collision | Chained linked list | Open addressing + bucket chaining |
| Memory/entry | ~56-72 bytes | ~20-30 bytes |
| Lookup cost | 4+ accesses | 2 accesses |
| SIMD | None | x86 SSE/AVX, ARM NEON |
