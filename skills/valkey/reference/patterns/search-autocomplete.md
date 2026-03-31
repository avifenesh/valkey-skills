# Search and Autocomplete Patterns

Use when building prefix autocomplete, tag-based filtering, search result ranking, or lightweight full-text search without external search engines.

## Contents

- Prefix Autocomplete with Sorted Sets (line 15)
- Scored Search Results (line 83)
- Tag-Based Search with Sets (line 126)
- Hash-Based Inverted Indexes (line 208)
- See Also (line 275)

---

## Prefix Autocomplete with Sorted Sets

Sorted sets with lexicographic range queries provide O(log N) prefix matching. Add all searchable terms with score 0, then query by prefix using `ZRANGEBYLEX`.

### Setup

```
# Add searchable terms (all score 0 for lexicographic ordering)
ZADD autocomplete 0 "apple"
ZADD autocomplete 0 "application"
ZADD autocomplete 0 "apply"
ZADD autocomplete 0 "banana"
ZADD autocomplete 0 "band"
```

### Query by Prefix

```
# Find all terms starting with "app"
ZRANGEBYLEX autocomplete "[app" "[app\xff"
# Returns: ["apple", "application", "apply"]

# With LIMIT for pagination
ZRANGEBYLEX autocomplete "[app" "[app\xff" LIMIT 0 5
```

The `[` means inclusive. The `\xff` byte ensures we capture all strings with the prefix.

**Modern syntax** (Valkey 6.2+ preferred):
```
ZRANGE autocomplete "[app" "[app\xff" BYLEX LIMIT 0 5
```

### Node.js

```javascript
async function autocomplete(redis, prefix, limit = 10) {
  return redis.zrangebylex(
    'autocomplete', `[${prefix}`, `[${prefix}\xff`, 'LIMIT', 0, limit
  );
}

// Usage
const suggestions = await autocomplete(redis, 'app');
// ["apple", "application", "apply"]
```

### Python

```python
async def autocomplete(redis, prefix: str, limit: int = 10):
    return await redis.zrangebylex(
        'autocomplete', f'[{prefix}', f'[{prefix}\xff', start=0, num=limit
    )

# Usage
suggestions = await autocomplete(redis, 'app')
# [b'apple', b'application', b'apply']
```

### Gotchas

- **Case sensitivity**: Store terms lowercased for case-insensitive search. Normalize at both index and query time.
- **Memory**: Each term is a sorted set member. For millions of terms, this uses significant memory. Consider sharding by first letter or using the hash bucketing technique for memory reduction.
- **Updates**: Use `ZREM` + `ZADD` to update terms. `ZADD` with a term that already exists just updates the score.

---

## Scored Search Results

When results need ranking (not just prefix matching), use non-zero scores to represent relevance. Higher scores appear first with `ZREVRANGE`.

```
# Index products with popularity scores
ZADD search:laptop 8500 "macbook-pro-16"
ZADD search:laptop 7200 "thinkpad-x1"
ZADD search:laptop 6800 "dell-xps-15"

# Top 5 results by popularity
ZREVRANGE search:laptop 0 4 WITHSCORES
```

### Combining Prefix Match with Score Ranking

Store terms in one sorted set for prefix lookup, and maintain a separate scored set for ranking:

```javascript
async function searchWithRanking(redis, prefix, limit = 10) {
  // Step 1: Get matching terms by prefix
  const matches = await redis.zrangebylex(
    'autocomplete', `[${prefix}`, `[${prefix}\xff`, 'LIMIT', 0, 50
  );
  if (matches.length === 0) return [];

  // Step 2: Get scores for matched terms
  const pipeline = redis.pipeline();
  for (const term of matches) {
    pipeline.zscore('popularity', term);
  }
  const scores = await pipeline.exec();

  // Step 3: Sort by score descending, return top N
  return matches
    .map((term, i) => ({ term, score: parseFloat(scores[i][1]) || 0 }))
    .sort((a, b) => b.score - a.score)
    .slice(0, limit);
}
```

---

## Tag-Based Search with Sets

Sets provide O(1) membership testing and O(N*M) intersection for multi-tag queries. Use when items have discrete tags and users filter by combinations.

### Indexing

```
# Add items to tag sets
SADD tag:electronics "product:100" "product:101" "product:102"
SADD tag:wireless "product:100" "product:103"
SADD tag:bluetooth "product:100" "product:104"
```

### Single Tag Query

```
SMEMBERS tag:electronics
# All products tagged "electronics"
```

### Multi-Tag Intersection

```
# Products that are BOTH electronics AND wireless
SINTER tag:electronics tag:wireless
# ["product:100"]

# Count matches without returning them (Valkey 7.0+)
SINTERCARD 2 tag:electronics tag:wireless
# 1

# With a LIMIT to stop counting early
SINTERCARD 2 tag:electronics tag:wireless LIMIT 100
```

`SINTERCARD` is useful for "show count" UIs where you need the number of matching items but not the items themselves.

### Union for OR Queries

```
# Products tagged electronics OR wireless
SUNION tag:electronics tag:wireless
```

### Node.js

```javascript
async function searchByTags(redis, tags, mode = 'AND') {
  const keys = tags.map(t => `tag:${t}`);
  if (mode === 'AND') {
    return redis.sinter(...keys);
  }
  return redis.sunion(...keys);
}

async function countByTags(redis, tags, limit = 0) {
  const keys = tags.map(t => `tag:${t}`);
  return redis.sintercard(keys.length, ...keys, ...(limit ? ['LIMIT', limit] : []));
}
```

### Python

```python
async def search_by_tags(redis, tags: list[str], mode: str = 'AND'):
    keys = [f'tag:{t}' for t in tags]
    if mode == 'AND':
        return await redis.sinter(*keys)
    return await redis.sunion(*keys)

async def count_by_tags(redis, tags: list[str], limit: int = 0):
    keys = [f'tag:{t}' for t in tags]
    return await redis.sintercard(len(keys), *keys, limit=limit)
```

### Gotchas

- **Large sets**: `SINTER` on sets with millions of members is expensive. Use `SINTERCARD` with LIMIT when you only need a count or existence check.
- **Cluster mode**: Multi-key set operations require all keys in the same hash slot. Use hash tags: `{product}:tag:electronics`, `{product}:tag:wireless`.

---

## Hash-Based Inverted Indexes

For more complex search scenarios where each document has multiple searchable fields, use hashes for document storage and sets for inverted indexes.

### Indexing

```
# Store document
HSET doc:1 title "Valkey Performance Guide" author "alice" category "database"

# Build inverted indexes (one set per term)
SADD idx:valkey "doc:1"
SADD idx:performance "doc:1"
SADD idx:guide "doc:1"
SADD idx:database "doc:1"
```

### Search

```
# Find docs matching ALL terms
SINTER idx:valkey idx:performance
# ["doc:1"]

# Fetch matching documents
pipeline:
  SINTER idx:valkey idx:performance  -> ["doc:1"]
  HGETALL doc:1                      -> {title: "...", author: "...", ...}
```

### Node.js

```javascript
async function indexDocument(redis, docId, fields, terms) {
  const pipeline = redis.pipeline();
  pipeline.hset(`doc:${docId}`, fields);
  for (const term of terms) {
    pipeline.sadd(`idx:${term.toLowerCase()}`, `doc:${docId}`);
  }
  await pipeline.exec();
}

async function searchDocuments(redis, terms) {
  const keys = terms.map(t => `idx:${t.toLowerCase()}`);
  const docIds = await redis.sinter(...keys);

  const pipeline = redis.pipeline();
  for (const id of docIds) {
    pipeline.hgetall(id);
  }
  const results = await pipeline.exec();
  return results.map(([err, doc]) => doc).filter(Boolean);
}
```

### When to Use This vs External Search

| Scenario | Recommendation |
|----------|---------------|
| Simple prefix autocomplete | Sorted set ZRANGEBYLEX |
| Tag filtering with AND/OR | Set SINTER/SUNION |
| Full-text search with relevance scoring | Use a dedicated search engine (Elasticsearch, Valkey Search module) |
| Real-time typeahead (< 10ms) | Sorted set autocomplete |
| Complex queries (fuzzy matching, stemming) | Dedicated search engine |

---

## See Also

- [Sorted Set Commands](../basics/data-types.md) - ZRANGEBYLEX, ZRANGE BYLEX, ZINCRBY for autocomplete
- [Set Commands](../basics/data-types.md) - SINTER, SUNION, SINTERCARD for tag-based search
- [Hash Commands](../basics/data-types.md) - HSET, HGETALL for document storage in inverted indexes
- [Leaderboard Patterns](leaderboards.md) - scored ranking patterns with sorted sets
- [Counter Patterns](counters.md) - HyperLogLog for approximate unique query counting
- [Caching Patterns](caching.md) - cache-aside for search result caching
- [Performance Best Practices](../best-practices/performance.md) - pipelining for batch lookups
- [Memory Best Practices](../best-practices/memory.md) - sorted set encoding thresholds for large indexes
- [Key Best Practices](../best-practices/keys.md) - hash tags for cluster co-location of index keys
- [Cluster Best Practices](../best-practices/cluster.md) - multi-key operations require same hash slot
- [High Availability Best Practices](../best-practices/high-availability.md) - replica reads for search queries
- [Security: Auth and ACL](../security/auth-and-acl.md) - ACL restrictions for index key namespaces
- Clients Overview (see valkey-glide skill) - auto-pipelining for batch index lookups
- [Anti-Patterns Quick Reference](../anti-patterns/quick-reference.md) - SMEMBERS on huge sets, big key issues with large indexes
