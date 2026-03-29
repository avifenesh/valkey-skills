# Skiplist - Probabilistic Sorted Structure

Use when working with sorted sets that exceed the listpack threshold. The skiplist provides O(log N) insert, delete, and range operations, plus O(log N) rank computation via span tracking.

Source: `src/t_zset.c`, `src/server.h`

---

## Overview

Valkey's skiplist is a modified version of William Pugh's "Skip Lists: A Probabilistic Alternative to Balanced Trees." It is used as half of the sorted set (zset) implementation - paired with a hashtable for O(1) element-to-score lookups. The skiplist provides score-ordered traversal and range operations.

Valkey's modifications from the standard skiplist:
- Allows repeated scores (ties broken by lexicographic comparison of elements)
- Backward pointer at level 0 for reverse traversal (ZREVRANGE)
- Span tracking at each level for O(log N) rank computation (ZRANK)
- Elements are embedded directly in skiplist nodes (no separate allocation)

## Core Structs

### zskiplistNode

```c
typedef struct zskiplistNode {
    union {
        double score;         /* Sorting score for node ordering. */
        unsigned long length; /* Number of elements (header node only). */
    };
    union {
        struct zskiplistNode *backward; /* Previous node (data nodes). */
        struct zskiplistNode *tail;     /* Tail pointer (header node only). */
    };
    struct zskiplistLevel {
        struct zskiplistNode *forward;
        unsigned long span;
    } level[1]; /* Flexible array - actual levels determined at creation. */
    /* For non-header nodes: sds-header-size (1 byte) + embedded sds element */
} zskiplistNode;
```

The node uses unions to save memory - the header node reuses `score` as `length` and `backward` as `tail`, since the header never stores actual data.

The level 0 span field is repurposed to store the node height, since level 0 span is always 1 (or 0 for the last node).

**Memory layout of a non-header node:**

```
+-------+------------------+---------+-----+---------+-----------------+-------------+
| score | backward-pointer | level-0 | ... | level-N | sds-header-size | element-sds |
+-------+------------------+---------+-----+---------+-----------------+-------------+
```

The SDS element is embedded directly after the level array, with a 1-byte prefix indicating the SDS header size. This improves cache locality and reduces allocations.

### zskiplist

```c
typedef struct zskiplist {
    zskiplistNode header;
} zskiplist;
```

The skiplist struct is minimal - just the header node. The header's `length` field (via union with `score`) stores the element count, and `tail` (via union with `backward`) points to the last element. The height is stored in `header.level[0].span`.

The header is allocated with `ZSKIPLIST_MAXLEVEL` (32) levels:

```c
size_t zslGetAllocSize(void) {
    return sizeof(zskiplist) + (ZSKIPLIST_MAXLEVEL - 1) * sizeof(struct zskiplistLevel);
}
```

### zset (the combined structure)

```c
typedef struct zset {
    hashtable *ht;    /* element -> score mapping for O(1) lookups */
    zskiplist *zsl;   /* score-ordered structure for range operations */
} zset;
```

Both structures share the same SDS element strings to avoid duplication.

## Level Randomization

```c
#define ZSKIPLIST_MAXLEVEL 32  /* Enough for 2^64 elements */

static int zslRandomLevel(void) {
    uint64_t rand = genrand64_int64();
    int level = rand == 0 ? ZSKIPLIST_MAXLEVEL
                          : (__builtin_clzll(rand) / 2 + 1);
    return level;
}
```

Each pair of leading zero bits in a random 64-bit number adds one level. This gives a probability of 0.25 (1/4) for each additional level - matching the classic skiplist probability parameter p=0.25.

| Level | Probability | Expected nodes (1M elements) |
|-------|------------|------------------------------|
| 1 | 75% | 750,000 |
| 2 | 18.75% | 187,500 |
| 3 | 4.69% | 46,875 |
| 4 | 1.17% | 11,719 |
| 8 | ~0.0015% | ~15 |
| 16 | ~0.0000002% | ~0 |

## Ordering

Nodes are sorted by (score, element) pairs:

```c
static int zslCompareNodes(const zskiplistNode *a, const zskiplistNode *b) {
    if (a == b) return 0;
    if (a == NULL) return 1;  /* NULL = end of list */
    if (b == NULL) return -1;
    if (a->score > b->score) return 1;
    if (a->score < b->score) return -1;
    return sdscmp(zslGetNodeElement(a), zslGetNodeElement(b));
}
```

When scores are equal, elements are compared lexicographically. This guarantees a total order.

## Key Operations

### Insert

```c
zskiplistNode *zslInsert(zskiplist *zsl, double score, const_sds ele);
```

1. Generate a random level for the new node
2. Traverse from the highest level, recording `update[]` (last node before insertion point at each level) and `rank[]` (cumulative span to reach that point)
3. If the new level exceeds the current height, extend the header's levels
4. Insert the node by updating forward pointers and recomputing spans
5. Set the backward pointer and update the tail if needed

The `update[]` and `rank[]` arrays are stack-allocated at `ZSKIPLIST_MAXLEVEL` (32) entries.

### Delete

```c
static void zslDelete(zskiplist *zsl, zskiplistNode *node);
```

Traverses to find the node's `update[]` array, then removes it by updating forward pointers and spans. If the deleted node was at the highest level, the skiplist height is reduced.

### Update Score

```c
static zskiplistNode *zslUpdateScore(zskiplist *zsl, zskiplistNode *node,
                                      double newscore);
```

Optimization: if the new score doesn't change the node's position (still between its neighbors), the score is updated in-place without remove/reinsert. Otherwise, the node is removed and reinserted at its new position, reusing the existing allocation.

### Range Queries

The skiplist supports several range query patterns used by ZRANGEBYSCORE, ZRANGEBYLEX, ZRANGEBYRANK:

```c
int zslValueGteMin(double value, zrangespec *spec);
int zslValueLteMax(double value, zrangespec *spec);
int zslLexValueGteMin(sds value, zlexrangespec *spec);
int zslLexValueLteMax(sds value, zlexrangespec *spec);
```

### Rank Lookup

```c
zskiplistNode *zslGetElementByRank(zskiplist *zsl, unsigned long rank);
```

Uses the span values to skip through nodes efficiently. Each level's span records how many elements are between the current node and the next node at that level, enabling O(log N) rank computation.

## Span Tracking

At each level, `span` records the number of elements between the current node and the next node at that level. This enables:

- **ZRANK**: Accumulate spans while descending to find rank
- **ZRANGEBYRANK**: Jump to a rank position in O(log N)

Exception: Level 0's span is repurposed to store the node height (since level 0 span is always 1 or 0).

```c
static inline unsigned long zslGetNodeSpanAtLevel(const zskiplistNode *x, int level) {
    if (level > 0) return x->level[level].span;
    return x->level[level].forward ? 1 : 0;
}
```

## Performance

| Operation | Average | Worst Case |
|-----------|---------|------------|
| Insert | O(log N) | O(N) |
| Delete | O(log N) | O(N) |
| Search by score | O(log N) | O(N) |
| Rank lookup | O(log N) | O(N) |
| Range (k elements) | O(log N + k) | O(N) |
| Reverse traversal | O(1) per step | O(1) per step |

The worst case is theoretical - with the randomization parameters used, it is vanishingly unlikely for large N.

## When Used

[See also: encoding-transitions.md](encoding-transitions.md) for the full transition table covering all data types.

Sorted sets use the skiplist encoding when either threshold is exceeded:

- `zset-max-listpack-entries` (default 128) - element count
- `zset-max-listpack-value` (default 64) - element byte size

Below these thresholds, sorted sets use listpack encoding.

## See Also

- [hashtable.md](hashtable.md) - The hashtable paired with the skiplist in `zset` for O(1) element-to-score lookups
- [listpack.md](listpack.md) - The compact encoding used for small sorted sets before skiplist conversion
- [encoding-transitions.md](encoding-transitions.md) - Threshold configs that trigger the listpack-to-skiplist conversion
- [sds.md](sds.md) - The SDS strings embedded directly in skiplist nodes
