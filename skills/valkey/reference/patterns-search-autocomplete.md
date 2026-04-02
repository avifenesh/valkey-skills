# Search and Autocomplete Patterns

Use when building prefix autocomplete, tag filtering, or lightweight search without an external search engine.

## Prefix Autocomplete

Store terms with score 0, query by prefix with `ZRANGEBYLEX`. Preferred modern syntax (Valkey 6.2+):

```
ZADD autocomplete 0 "apple"
ZADD autocomplete 0 "application"
ZRANGE autocomplete "[app" "[app\xff" BYLEX LIMIT 0 10
```

Store terms lowercased for case-insensitive matching. For ranked results alongside prefix match, keep a separate scored sorted set and join in application code.

## Tag Filtering

`SINTER` for AND, `SUNION` for OR. `SINTERCARD` (added in Redis/Valkey 7.0) returns count without fetching members - useful for "X results" UI counters with an early-stop LIMIT.

Cluster mode: multi-key set operations require all keys in the same slot - use hash tags `{ns}:tag:electronics`.

## When to Use valkey-search Instead

| Need | Recommendation |
|------|---------------|
| Simple prefix autocomplete | `ZRANGEBYLEX` sorted set |
| Tag AND/OR filtering | `SINTER` / `SUNION` sets |
| Full-text, fuzzy, stemming | valkey-search module (see `valkey-modules` skill) |
| Relevance scoring with field weights | valkey-search module |

The valkey-search module supports `FT.SEARCH` with full-text indexes, numeric filters, geo filters, and vector similarity - all inside Valkey without an external engine.
