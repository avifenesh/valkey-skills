# Batch Key Prefetching

Use when you need to understand how Valkey amortizes memory access latency
across multiple commands in a pipeline, or when investigating the
`prefetch-batch-max-size` configuration.

Source: `src/memory_prefetch.c`, `src/memory_prefetch.h`

## Contents

- Problem: Memory Access Is the Bottleneck (line 23)
- Solution: Interleaved Prefetching (line 36)
- Data Structures (line 48)
- How Prefetching Works (line 96)
- Batch Management (line 209)
- Configuration (line 244)
- Performance Impact (line 252)
- Statistics (line 268)
- See Also (line 277)

---

## Problem: Memory Access Is the Bottleneck

In a high-throughput Valkey server, the `lookupKey` operation dominates main
thread time (>40%). Each key lookup requires multiple dependent memory accesses:
hashtable bucket, then entry, then value object. Each of these can be an L2/L3
cache miss (100-300 CPU cycles per miss). With millions of keys, almost every
lookup misses the L1 cache.

Traditional single-command processing wastes these cycles - the CPU stalls
waiting for memory while all other pending commands sit idle.

---

## Solution: Interleaved Prefetching

Instead of processing commands one at a time, Valkey batches multiple commands
and uses CPU prefetch instructions to overlap memory fetches across them. While
waiting for one key's memory to arrive in cache, the CPU issues prefetches for
the next key.

This optimization was introduced in Valkey 8.0 for I/O thread batches and
extended in 9.0 for pipelined commands from single clients.

---

## Data Structures

### PrefetchState

```c
typedef enum {
    PREFETCH_ENTRY,  // Initial: prefetch hashtable entries for this key
    PREFETCH_VALUE,  // Prefetch the value object of the found entry
    PREFETCH_DONE    // Prefetching complete for this key
} PrefetchState;
```

### KeyPrefetchInfo

```c
typedef struct KeyPrefetchInfo {
    PrefetchState state;
    hashtableIncrementalFindState hashtab_state;
} KeyPrefetchInfo;
```

Each key in the batch has one of these. The `hashtab_state` tracks progress
through the incremental hashtable lookup, which issues prefetch instructions
at each step.

### PrefetchCommandsBatch

```c
typedef struct PrefetchCommandsBatch {
    size_t cur_idx;            // Current key index in round-robin
    size_t keys_done;          // Keys that completed prefetching
    size_t key_count;          // Total keys in batch
    size_t client_count;       // Total clients in batch
    size_t max_prefetch_size;  // Batch capacity
    size_t executed_commands;  // Commands processed so far
    int *slots;                // Cluster slot per key
    void **keys;               // Key pointers
    client **clients;          // Client pointers
    hashtable **keys_tables;   // Main hashtable per key
    KeyPrefetchInfo *prefetch_info;
} PrefetchCommandsBatch;
```

A single static batch is allocated at startup and reused. Its size is
controlled by `server.prefetch_batch_max_size`.

---

## How Prefetching Works

### Phase 1: Collect

`addCommandToBatchAndProcessIfFull()` is called for each client with a pending
command. It extracts the key positions from the command and adds them to the
batch:

```c
static void addCommandToBatch(struct serverCommand *cmd, robj **argv,
                              int argc, serverDb *db, int slot) {
    getKeysResult result;
    int num_keys = getKeysFromCommand(cmd, argv, argc, &result);
    for (int i = 0; i < num_keys && batch->key_count < max; i++) {
        batch->keys[batch->key_count] = argv[result.keys[i].pos];
        batch->keys_tables[batch->key_count] =
            kvstoreGetHashtable(db->keys, slot);
        batch->key_count++;
    }
}
```

It also collects queued pipeline commands from `c->cmd_queue`.

### Phase 2: Prefetch

When the batch is full (or all pending clients are added), `prefetchCommands()`
runs three sub-phases:

1. **Prefetch argv objects** - bring command argument robj structs into cache
2. **Prefetch argv values** - bring the sds string data of arguments into cache
3. **Prefetch hashtable entries** - the core optimization

The hashtable prefetch uses incremental find operations that issue `__builtin_prefetch`
at each step of the lookup:

```c
static void hashtablePrefetch(hashtable **tables) {
    initBatchInfo(tables);
    KeyPrefetchInfo *info;
    while ((info = getNextPrefetchInfo())) {
        switch (info->state) {
        case PREFETCH_ENTRY: prefetchEntry(info); break;
        case PREFETCH_VALUE: prefetchValue(info); break;
        }
    }
}
```

The round-robin `getNextPrefetchInfo()` cycles through all keys in the batch.
Each call advances one key by one step:

```c
static void prefetchEntry(KeyPrefetchInfo *info) {
    if (hashtableIncrementalFindStep(&info->hashtab_state)) {
        moveToNextKey();  // Not done yet, move to next key
    } else {
        // Entry found or miss, optionally prefetch value
        info->state = PREFETCH_VALUE;
    }
}
```

By interleaving steps across different keys, the CPU issues prefetch for
key B while waiting for key A's memory to arrive. The
`hashtableIncrementalFindStep()` function is designed to do one memory access
per call, making it ideal for interleaving.

For value prefetching:

```c
static void prefetchValue(KeyPrefetchInfo *info) {
    void *entry;
    if (hashtableIncrementalFindGetResult(&info->hashtab_state, &entry)) {
        robj *val = entry;
        if (val->encoding == OBJ_ENCODING_RAW && val->type == OBJ_STRING) {
            valkey_prefetch(objectGetVal(val));
        }
    }
    markKeyAsdone(info);
}
```

Value prefetching is skipped when copy-avoidance is active (when
`io_threads_num >= min_io_threads_copy_avoid`), since in that mode the I/O
thread writes directly from the value buffer, and prefetching would bring data
into the wrong CPU core's cache.

### Phase 3: Execute

After prefetching, `processClientsCommandsBatch()` executes all commands in
order. By the time `lookupKey` runs for each key, the relevant hashtable
bucket and value are likely already in L1/L2 cache.

```c
void processClientsCommandsBatch(void) {
    if (batch->executed_commands == 0) {
        prefetchCommands();
    }
    for (size_t i = 0; i < batch->client_count; i++) {
        client *c = batch->clients[i];
        if (c == NULL) continue;
        batch->clients[i] = NULL;
        batch->executed_commands++;
        if (processPendingCommandAndInputBuffer(c) != C_ERR)
            beforeNextClient(c);
    }
    resetCommandsBatch();
}
```

---

## Batch Management

### Initialization

```c
void prefetchCommandsBatchInit(void) {
    if (server.prefetch_batch_max_size == 0) return;
    batch = zcalloc(sizeof(PrefetchCommandsBatch));
    batch->max_prefetch_size = server.prefetch_batch_max_size;
    // Allocate arrays for clients, keys, tables, slots, prefetch_info
}
```

Called during `initIOThreads()` and whenever the max size config changes.

### Dynamic Resize

```c
int onMaxBatchSizeChange(const char **err);
```

Called when `prefetch-batch-max-size` is updated at runtime. Frees and
reallocates the batch if no commands are currently being processed.

### Client Removal

```c
void removeClientFromPendingCommandsBatch(client *c);
```

If a client disconnects or is freed while its command is in the batch, this
sets its slot to NULL so it is skipped during execution.

---

## Configuration

| Config | Default | Description |
|--------|---------|-------------|
| `prefetch-batch-max-size` | 16 | Max keys (and clients) per prefetch batch. 0 disables. |

---

## Performance Impact

From the research guide:

- Batch prefetching + I/O threads: 780K to 1.19M SET ops/sec (~50% improvement)
- Reduces the `lookupKey` bottleneck by >80%
- Pipeline prefetching (9.0): up to 40% additional throughput for pipelined
  workloads

The optimization is most effective when:
- Many clients send commands concurrently (more keys per batch)
- Keys are spread across memory (more cache misses to amortize)
- Commands are simple (GET/SET) so the prefetch overhead is proportionally small

---

## Statistics

| Metric | Description |
|--------|-------------|
| `stat_total_prefetch_batches` | Number of batches processed |
| `stat_total_prefetch_entries` | Number of keys prefetched |

---

## See Also

- [Hashtable](../data-structures/hashtable.md) - the `hashtableIncrementalFindStep()` function is designed for one memory access per call, enabling the interleaved prefetch pattern
- [I/O Threads](../threading/io-threads.md) - prefetch batches are collected from clients whose commands were read by I/O threads; `prefetchCommandsBatchInit()` is called from `initIOThreads()`
- [Database Management](../config/db-management.md) - `lookupKey()` is the hot path that prefetching optimizes by bringing hashtable buckets and value objects into cache before execution
