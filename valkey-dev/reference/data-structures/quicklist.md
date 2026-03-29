# Quicklist - Doubly-Linked List of Listpacks

Use when working with the List data type at full encoding. Quicklist combines the memory efficiency of listpack with O(1) push/pop at both ends.

Source: `src/quicklist.c`, `src/quicklist.h`

---

## Overview

A quicklist is a doubly-linked list where each node contains a listpack (or a single plain element for oversized entries). It is the full encoding for the List data type. Interior nodes can be LZF-compressed to save memory, while head and tail nodes remain uncompressed for fast access.

## Core Structs

### quicklistNode (40 bytes on 64-bit)

```c
typedef struct quicklistNode {
    struct quicklistNode *prev;
    struct quicklistNode *next;
    unsigned char *entry;
    size_t sz;                           /* entry size in bytes */
    unsigned int count : 16;             /* count of items in listpack */
    unsigned int encoding : 2;           /* RAW==1 or LZF==2 */
    unsigned int container : 2;          /* PLAIN==1 or PACKED==2 */
    unsigned int recompress : 1;         /* was this node previously compressed? */
    unsigned int attempted_compress : 1; /* node can't compress; too small */
    unsigned int dont_compress : 1;      /* prevent compression of entry */
    unsigned int extra : 9;              /* reserved for future use */
} quicklistNode;
```

| Field | Purpose |
|-------|---------|
| `entry` | Pointer to the listpack (PACKED) or raw data (PLAIN) |
| `sz` | Byte size of entry. For LZF nodes, this is the uncompressed size |
| `count` | Number of items in the listpack (max 65536 via 16 bits) |
| `encoding` | RAW (1) = uncompressed, LZF (2) = compressed |
| `container` | PACKED (2) = listpack with multiple items, PLAIN (1) = single item as raw bytes |

### quicklistLZF (compressed node data)

```c
typedef struct quicklistLZF {
    size_t sz;         /* LZF compressed size in bytes */
    char compressed[];
} quicklistLZF;
```

When a node is compressed, `node->entry` points to a `quicklistLZF` struct. The uncompressed size is stored in `node->sz`.

### quicklist (40 bytes on 64-bit)

```c
typedef struct quicklist {
    quicklistNode *head;
    quicklistNode *tail;
    unsigned long count;                  /* total count of all entries in all listpacks */
    unsigned long len;                    /* number of quicklistNodes */
    signed int fill : QL_FILL_BITS;       /* fill factor for individual nodes */
    unsigned int compress : QL_COMP_BITS; /* depth of end nodes not to compress; 0=off */
    unsigned int bookmark_count : QL_BM_BITS;
    quicklistBookmark bookmarks[];
} quicklist;
```

### quicklistIter / quicklistEntry

```c
typedef struct quicklistIter {
    quicklist *quicklist;
    quicklistNode *current;
    unsigned char *zi;   /* points to the current element within the listpack */
    long offset;         /* offset in current listpack */
    int direction;
} quicklistIter;

typedef struct quicklistEntry {
    const quicklist *quicklist;
    quicklistNode *node;
    unsigned char *zi;
    unsigned char *value;
    long long longval;
    size_t sz;
    int offset;
} quicklistEntry;
```

## Fill Factor (`list-max-listpack-size`)

The `fill` field controls how large each listpack node can grow. It accepts two types of values:

**Positive values**: Maximum number of entries per node.

**Negative values**: Maximum node size in bytes (using predefined levels):

| Fill Value | Max Node Size | Config Name |
|-----------|---------------|-------------|
| -1 | 4096 bytes | |
| -2 (default) | 8192 bytes | `list-max-listpack-size -2` |
| -3 | 16384 bytes | |
| -4 | 32768 bytes | |
| -5 | 65536 bytes | |

```c
static const size_t optimization_level[] = {4096, 8192, 16384, 32768, 65536};
```

The limit logic:

```c
void quicklistNodeLimit(int fill, size_t *size, unsigned int *count) {
    // Positive fill: use count limit with 8KB safety size limit
    // Negative fill: use size limit from optimization_level[]
}
```

## Compression (`list-compress-depth`)

Controls how many nodes at each end remain uncompressed:

| Config Value | Meaning |
|-------------|---------|
| 0 (default) | No compression |
| 1 | Head and tail nodes uncompressed, all others compressed |
| 2 | 2 nodes at each end uncompressed |
| N | N nodes at each end uncompressed |

Compression uses LZF (fast, low-ratio). Minimum size for compression attempt: 48 bytes (`MIN_COMPRESS_BYTES`). Minimum improvement required: 8 bytes (`MIN_COMPRESS_IMPROVE`).

When a compressed node needs to be read (e.g., for iteration or index access), it is temporarily decompressed and the `recompress` flag is set. After the operation, the node is recompressed.

## PLAIN Nodes

When an individual element exceeds the packed threshold, it gets its own node with `container = PLAIN` instead of being wrapped in a listpack. This avoids listpack overhead for large values. The threshold is based on the `fill` configuration - elements larger than the node size limit get their own PLAIN node.

## Key Operations

### Creation

```c
quicklist *quicklistCreate(void);
quicklist *quicklistNew(int fill, int compress);
void quicklistRelease(quicklist *quicklist);
```

Default fill is -2 (8KB nodes).

### Push / Pop

```c
int quicklistPushHead(quicklist *quicklist, void *value, const size_t sz);
int quicklistPushTail(quicklist *quicklist, void *value, const size_t sz);
void quicklistPush(quicklist *quicklist, void *value, const size_t sz, int where);
int quicklistPop(quicklist *quicklist, int where, unsigned char **data,
                 size_t *sz, long long *slong);
```

Push returns 1 if a new node was created, 0 if inserted into an existing node. When pushing, if the head/tail node is full (exceeds fill limit), a new node is created.

### Insert

```c
void quicklistInsertBefore(quicklistIter *iter, quicklistEntry *entry,
                           void *value, const size_t sz);
void quicklistInsertAfter(quicklistIter *iter, quicklistEntry *entry,
                          void *value, const size_t sz);
```

Insert may split nodes or merge adjacent nodes to maintain the fill constraint.

### Delete

```c
void quicklistDelEntry(quicklistIter *iter, quicklistEntry *entry);
int quicklistDelRange(quicklist *quicklist, const long start, const long stop);
```

After deletion, if a node becomes empty, it is removed from the linked list.

### Iteration

```c
quicklistIter *quicklistGetIterator(quicklist *quicklist, int direction);
quicklistIter *quicklistGetIteratorAtIdx(quicklist *quicklist, int direction,
                                          const long long idx);
int quicklistNext(quicklistIter *iter, quicklistEntry *entry);
void quicklistReleaseIterator(quicklistIter *iter);
```

Directions: `AL_START_HEAD` (0) or `AL_START_TAIL` (1).

### Index Access

```c
quicklistIter *quicklistGetIteratorEntryAtIdx(quicklist *quicklist,
                                               const long long index,
                                               quicklistEntry *entry);
int quicklistReplaceAtIndex(quicklist *quicklist, long index, void *data,
                            const size_t sz);
```

Index access is O(n) in the number of nodes, then O(m) within the target listpack.

## Node Merging and Splitting

When inserting into the middle of a full node, the quicklist:

1. Splits the target node at the insertion point (`_quicklistSplitNode`)
2. Inserts the new element
3. Attempts to merge adjacent nodes if they would fit within the fill limit (`_quicklistMergeNodes`)

Merge attempts check: center with prev, center with next, center-prev with center-next.

## Bookmarks

Bookmarks allow marking specific nodes by name for O(1) access during long traversals:

```c
int quicklistBookmarkCreate(quicklist **ql_ref, const char *name, quicklistNode *node);
quicklistNode *quicklistBookmarkFind(quicklist *ql, const char *name);
int quicklistBookmarkDelete(quicklist *ql, const char *name);
```

Limited to `QL_MAX_BM` (15) bookmarks. Only useful for very large lists.

## Performance

| Operation | Complexity |
|-----------|-----------|
| Push head/tail | O(1) amortized |
| Pop head/tail | O(1) amortized |
| Index access | O(n) nodes + O(m) within listpack |
| Insert at position | O(n) + possible split/merge |
| Length | O(1) (cached in quicklist->count) |
| Iteration (full) | O(N) total elements |

## See Also

- [listpack.md](listpack.md) - The compact encoding stored inside each quicklist node
- [encoding-transitions.md](encoding-transitions.md) - When lists convert from listpack to quicklist and back
