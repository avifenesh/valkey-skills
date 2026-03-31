---
name: valkey-json-dev
description: "Use when contributing to valkey-io/valkey-json source code - C++ internals, RapidJSON DOM, JSONPath engine, RDB serialization, dom_alloc layers. Not for using JSON.SET/GET in apps (valkey-modules) or building new modules (valkey-module-dev)."
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

- JDocument, JValue, RapidJSON, RapidJsonAllocator, GenericValue, type system, SIMD, object hash table -> Architecture
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
| JDocument/JValue DOM, RapidJSON allocator, object hash table, JSONPath engine, KeyTable, memory layers, RDB format, defrag | [architecture](reference/architecture.md) |
| build.sh, CMake, GoogleTest unit tests, pytest integration tests, ASAN, CI pipeline | [build-and-test](reference/build-and-test.md) |
| Adding commands, extending JSONPath, RDB versioning, coding conventions, PR checklist | [contributing](reference/contributing.md) |

## Quick Reference

```bash
./build.sh              # Release build -> build/src/libjson.so
./build.sh --unit       # Build + run GoogleTest unit tests
./build.sh --integration  # Build module + valkey-server, run pytest
./build.sh --clean      # Clean all artifacts
ASAN_BUILD=true ./build.sh --integration  # ASAN build
valkey-server --loadmodule ./build/src/libjson.so
```

Commands: `JSON.SET`, `JSON.MSET`, `JSON.GET`, `JSON.MGET`, `JSON.DEL`, `JSON.FORGET`, `JSON.ARRAPPEND`, `JSON.ARRINDEX`, `JSON.ARRINSERT`, `JSON.ARRLEN`, `JSON.ARRPOP`, `JSON.ARRTRIM`, `JSON.CLEAR`, `JSON.NUMINCRBY`, `JSON.NUMMULTBY`, `JSON.OBJKEYS`, `JSON.OBJLEN`, `JSON.RESP`, `JSON.STRLEN`, `JSON.STRAPPEND`, `JSON.TOGGLE`, `JSON.TYPE`, `JSON.DEBUG`
