# Rax - Radix Tree

Use when you need a memory-efficient, prefix-compressed tree for byte-string keys with ordered iteration. Used by Streams (consumer groups, stream IDs) and cluster fail_reports tracking.

Source: `src/rax.c`, `src/rax.h`

---

## Overview

Rax is a compressed radix tree (also called a Patricia trie or compact prefix tree). It stores keys as byte sequences, compressing chains of single-child nodes into a single node containing the full substring. Lookup is O(k) where k is the key length, independent of the number of keys stored.

## Visual Example (from source)

Inserting "foo", "foobar", and "footer":

```
Uncompressed:                    Compressed:

     (f) ""                         ["foo"] ""
       \                               |
       (o) "f"                      [t   b] "foo"
         \                          /     \
         (o) "fo"         "foot" ("er")    ("ar") "foob"
           \                        /          \
         [t   b] "foo"   "footer" []          [] "foobar"
         /     \
  (e)  "foot"  (a) "foob"
   /             \
  (r)            (r)
  /               \
 [] "footer"     [] "foobar"
```

Compression merges chains of single-child nodes. The string "foo" in a compressed node represents three levels collapsed into one.

## Core Structs

### raxNode

```c
#define RAX_NODE_MAX_SIZE ((1 << 29) - 1)

typedef struct raxNode {
    uint32_t iskey : 1;   /* Does this node contain a key? */
    uint32_t isnull : 1;  /* Associated value is NULL (don't store it). */
    uint32_t iscompr : 1; /* Node is compressed. */
    uint32_t size : 29;   /* Number of children, or compressed string len. */
    unsigned char data[];
} raxNode;
```

| Field | Purpose |
|-------|---------|
| `iskey` | This node represents a key in the tree (not just a prefix) |
| `isnull` | Key exists but has NULL value (saves 8 bytes per valueless key) |
| `iscompr` | Compressed node (single-child chain) vs branching node |
| `size` | For branching: number of children. For compressed: length of string |

### Node Data Layout

**Branching node** (`iscompr=0`):

```
[header iscompr=0][abc][a-ptr][b-ptr][c-ptr](value-ptr?)
```

- `size` bytes of character labels (one per child)
- `size` child pointers (`raxNode *`), aligned
- Optional value pointer (if `iskey=1` and `isnull=0`)

**Compressed node** (`iscompr=1`):

```
[header iscompr=1][xyz][z-ptr](value-ptr?)
```

- `size` bytes of the compressed string
- Exactly 1 child pointer (to the node after the compressed sequence)
- Optional value pointer

Child pointers are aligned to `sizeof(void *)` boundaries with padding after the character data:

```c
#define raxPadding(nodesize) \
    ((sizeof(void *) - (((nodesize) + 4) % sizeof(void *))) & (sizeof(void *) - 1))
```

### rax (tree root)

```c
typedef struct rax {
    raxNode *head;     /* Pointer to root node */
    uint64_t numele;   /* Number of keys in the tree */
    uint64_t numnodes; /* Number of rax nodes */
    size_t alloc_size; /* Total allocation size in bytes */
} rax;
```

### raxIterator

```c
#define RAX_ITER_STATIC_LEN 128

typedef struct raxIterator {
    int flags;
    rax *rt;
    unsigned char *key;     /* Current key buffer */
    void *data;             /* Data associated with current key */
    size_t key_len;
    size_t key_max;         /* Max key len the buffer can hold */
    unsigned char key_static_string[RAX_ITER_STATIC_LEN];
    raxNode *node;          /* Current node (unsafe iteration only) */
    raxStack stack;         /* Parent node stack for traversal */
    raxNodeCallback node_cb; /* Optional callback per node */
} raxIterator;
```

The iterator uses a static 128-byte buffer for short keys, falling back to heap allocation for longer ones.

### raxStack

```c
#define RAX_STACK_STATIC_ITEMS 32

typedef struct raxStack {
    void **stack;
    size_t items, maxitems;
    void *static_items[RAX_STACK_STATIC_ITEMS];
    int oom;
} raxStack;
```

Uses a stack-allocated array for the first 32 entries, growing to heap if needed. Tracks parent nodes during tree walks for operations that need to navigate upward.

## Key Operations

### Lifecycle

```c
rax *raxNew(void);
void raxFree(rax *rax);
void raxFreeWithCallback(rax *rax, void (*free_callback)(void *));
```

A new rax starts with an empty root node. `raxFreeWithCallback` allows freeing stored values during tree destruction.

### Insert and Remove

```c
int raxInsert(rax *rax, unsigned char *s, size_t len, void *data, void **old);
int raxTryInsert(rax *rax, unsigned char *s, size_t len, void *data, void **old);
int raxRemove(rax *rax, unsigned char *s, size_t len, void **old);
```

`raxInsert` overwrites if the key exists (returns 0, stores old value in `*old`). `raxTryInsert` does not overwrite existing keys (returns 0 without modifying).

Insert may require **node splitting** when a new key diverges from a compressed node's string. For example, inserting "first" into a tree containing "foo" requires splitting the "foo" compressed node at "f" to create a branching node.

Remove may require **node merging** - if removal creates a chain of single-child nodes, they are compressed back into one.

### Find

```c
int raxFind(rax *rax, unsigned char *s, size_t len, void **value);
```

Returns 1 if found (value stored in `*value`), 0 if not found.

### Iteration

```c
void raxStart(raxIterator *it, rax *rt);
int raxSeek(raxIterator *it, const char *op, unsigned char *ele, size_t len);
int raxNext(raxIterator *it);
int raxPrev(raxIterator *it);
void raxStop(raxIterator *it);
int raxEOF(raxIterator *it);
int raxCompare(raxIterator *iter, const char *op, unsigned char *key, size_t key_len);
```

Seek operators: `>`, `>=`, `<`, `<=`, `=`, `^` (minimum/first), `$` (maximum/last).

Iterator flags:
- `RAX_ITER_JUST_SEEKED` - Return current element on first Next/Prev call
- `RAX_ITER_EOF` - End of iteration reached
- `RAX_ITER_SAFE` - Safe iteration (allows modifications, but slower)

### Utility

```c
uint64_t raxSize(rax *rax);       /* Number of keys */
size_t raxAllocSize(rax *rax);    /* Total memory used */
void raxShow(rax *rax);           /* Debug: print tree structure */
int raxRandomWalk(raxIterator *it, size_t steps); /* Random traversal */
```

## Where Used in Valkey

| Subsystem | Purpose | Key Type | Value Type |
|-----------|---------|----------|------------|
| Streams | Stream ID index | Stream ID bytes | Listpack of entries |
| Streams | Consumer groups | Group name | Consumer group struct |
| Streams | Pending entries (PEL) | Stream ID | Pending entry struct |
| Cluster | Fail reports tracking | Node ID bytes | Fail report struct |

Streams are the primary user. Each stream stores its entries in a rax where keys are 128-bit stream IDs (millisecond timestamp + sequence number) and values are listpacks containing the field-value pairs for entries sharing a prefix.

## Performance

| Operation | Complexity | Notes |
|-----------|-----------|-------|
| Find | O(k) | k = key length |
| Insert | O(k) | May require node split |
| Remove | O(k) | May require node merge |
| Iterate next/prev | O(k) amortized | k = key length at each step |
| Memory per node | Variable | 4-byte header + chars + pointers + padding |

The tree is memory-sparse compared to a traditional trie because compressed nodes represent multiple levels in a single allocation.

## See Also

- [listpack.md](listpack.md) - Stored as values in the rax for Stream entries
- [../valkey-specific/vector-sets.md](../valkey-specific/vector-sets.md) - The vset uses a rax for time-bucket organization at scale
