---
name: valkey-modules
description: "Use when working with Valkey modules in applications: valkey-search (FT.CREATE/FT.SEARCH/FT.AGGREGATE), valkey-json (JSON.SET/GET, JSONPath), valkey-bloom (BF.ADD/EXISTS). Not for building custom modules (valkey-module-dev)."
version: 1.0.0
argument-hint: "[module name or query type]"
---

# Valkey Modules - User Reference

## Routing

- Vector search, full-text search, hybrid queries, indexing -> Search
- JSON documents, nested objects, JSONPath queries -> JSON
- Bloom filters, probabilistic membership, deduplication -> Bloom
- Module comparison, which module for what -> Overview
- Missing features, RediSearch/RedisJSON gaps -> Gaps

## Modules

| Topic | Reference |
|-------|-----------|
| valkey-search: vector, full-text, tag, numeric search, FT.CREATE/SEARCH/AGGREGATE, hybrid queries | [search](reference/search.md) |
| valkey-json: JSON documents, JSONPath, JSON.SET/GET/MGET/MSET/DEL/FORGET/ARRAPPEND, nested objects | [json](reference/json.md) |
| valkey-bloom: BF.ADD/EXISTS/RESERVE, BF.MADD/MEXISTS, BF.INSERT, BF.INFO/CARD, scalable filters | [bloom](reference/bloom.md) |
| Module overview: versions, compatibility, valkey-bundle image, loading modules | [overview](reference/overview.md) |
| Feature gaps: what RediSearch/RedisJSON has that valkey equivalents don't yet | [gaps](reference/gaps.md) |
