---
name: valkey-modules
description: "Valkey module usage in applications - valkey-search (FT.CREATE/FT.SEARCH/FT.AGGREGATE), valkey-json (JSON.SET/GET, JSONPath), valkey-bloom (BF.ADD/EXISTS). Not for building custom modules (use valkey-module-dev)."
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
| valkey-json: JSON documents, JSONPath, JSON.SET/GET/MGET/MSET/DEL/FORGET/ARRAPPEND, nested objects, RedisJSON compatibility, when to use | [json](reference/json.md) |
| valkey-bloom: BF.ADD/EXISTS/RESERVE, BF.MADD/MEXISTS, BF.INSERT, BF.INFO/CARD, scalable filters, error rate and memory, use cases | [bloom](reference/bloom.md) |
| Module overview: versions, compatibility, valkey-bundle image, loading modules, when to use modules vs core features | [overview](reference/overview.md) |
| Feature gaps: Redis 8 vs Valkey 9 module comparison, time series, graph, probabilistic structures, workarounds | [gaps](reference/gaps.md) |
