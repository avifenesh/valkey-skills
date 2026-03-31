---
name: valkey-json-dev
description: "Use when contributing to valkey-io/valkey-json - C++ module internals, JDocument/RapidJSON DOM, JSONPath engine, KeyTable interning, RDB serialization, dom_alloc memory layers, building from source, or reviewing PRs."
version: 1.0.0
argument-hint: "[area or task]"
---

# Valkey JSON Module - Contributor Reference

C++ module implementing JSON document storage with JSONPath queries, backed by a modified RapidJSON DOM.

## Not This Skill

- Using JSON.SET/GET/MGET commands in applications -> use valkey-modules
- Building custom Valkey modules from scratch -> use valkey-module-dev
- ValkeyModule_* C API reference -> use valkey-module-dev

## Routing

- JDocument, JValue, RapidJSON, RapidJsonAllocator, GenericValue, type system, SIMD -> Architecture
- Selector, JSONPath v1/v2, filter expressions, recursive descent, slices, wildcards -> Architecture
- KeyTable, string interning, shard table, ref-counting, PtrWithMetaData, FNV-1a -> Architecture
- dom_alloc, memory traps, jsn:: namespace, three-layer allocator, defrag -> Architecture
- RDB encver 3, encver 0, metacodes, dom_save, dom_load, backward compat -> Architecture
- build.sh, CMake, GoogleTest, unit tests, pytest, ASAN, LeakSanitizer, CI matrix -> Build and Test
- Adding commands, Command_JsonXxx, command flags, ACL categories, key-spec -> Contributing
- Extending JSONPath, Lexer, Token, parseBracketPathElement, resultSet, insertPaths -> Contributing
- RDB versioning, DOCUMENT_TYPE_ENCODING_VERSION, coding conventions, jsn:: types -> Contributing
- SharedJSON_Get, cross-module API, CONFIG SET json.*, ReplicateVerbatim, PR checklist -> Contributing

## Reference

| Topic | Reference |
|-------|-----------|
| JDocument/JValue DOM, RapidJSON allocator, JSONPath engine, KeyTable, memory layers, RDB format, defrag | [architecture](reference/architecture.md) |
| build.sh, CMake, GoogleTest unit tests, pytest integration tests, ASAN, CI pipeline | [build-and-test](reference/build-and-test.md) |
| Adding commands, extending JSONPath, RDB versioning, coding conventions, PR checklist | [contributing](reference/contributing.md) |

## Quick Reference

```
src/json/json.cc        Module entry, command handlers, RDB callbacks, config
src/json/dom.cc/.h      JDocument/JValue tree, CRUD, parse, serialize, RDB
src/json/selector.cc/.h JSONPath v1 (legacy) + v2 (dollar) parser/evaluator
src/json/keytable.cc/.h Sharded string interning (ref-counted, FNV-1a)
src/json/alloc.cc/.h    dom_alloc/dom_free wrapping ValkeyModule_Alloc
src/json/memory.cc/.h   Memory traps, jsn:: STL allocator
src/json/stats.cc/.h    Memory tracking, histograms, INFO metrics
src/json/util.cc/.h     JsonUtilCode errors, number formatting
src/json/json_api.cc/.h Cross-module C API (SharedJSON_Get)
src/rapidjson/          Vendored RapidJSON (SSE4.2/NEON, 48-bit pointers)
```
