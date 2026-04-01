---
name: valkey-json-dev
description: "Use when contributing to valkey-io/valkey-json source code - C++ internals, RapidJSON DOM, JSONPath engine, RDB serialization, defrag, cross-module API, build system. Not for using JSON commands in apps (valkey-modules) or building custom modules (valkey-module-dev)."
version: 1.0.0
argument-hint: "[subsystem or source file]"
---

# Valkey JSON Module - Contributor Reference

14 source-verified reference docs covering the valkey-json C++ module - document DOM, JSONPath engine, persistence, cross-module integration, build, and test infrastructure.

Browse by subsystem below or ask about a specific topic. Each link leads to a focused reference doc with struct definitions, function signatures, and implementation details verified against the actual C++ source.

## Routing

- JDocument, JValue, RJValue, JParser, RapidJsonAllocator, GenericValue, type system -> Document Model (jdocument)
- Object member storage, vector mode, hash table mode, GenericMemberHT, conversion threshold -> Document Model (object-hashtable)
- KeyTable, string interning, shard table, ref-counting, PtrWithMetaData, FNV-1a -> Document Model (keytable)
- dom_alloc, memory traps, jsn:: namespace, three-layer allocator, TLS tracking -> Document Model (memory-layers)
- Selector, JSONPath v1/v2, Lexer, Token types, EBNF grammar, safety limits -> JSONPath Engine (selector)
- Filter expressions, comparison operators, boolean logic, attribute existence -> JSONPath Engine (expressions)
- Dot/bracket notation, wildcards, recursive descent, slices, index unions -> JSONPath Engine (path-operations)
- RDB encver 3, encver 0, metacodes, dom_save, dom_load, AOF rewrite -> Persistence (rdb-format)
- Defragmentation, defrag_threshold, copy-swap, dom_copy, defrag stats -> Persistence (defrag)
- SharedJSON_Get, cross-module API, CONFIG SET json.*, KeyTable tuning -> Cross-Module (cross-module)
- build.sh, CMake, dependencies, compiler flags, SIMD, ASAN, libjson.so -> Build (build)
- GoogleTest, unit tests, module_sim stubs, pytest, JsonTestCase -> Build (testing)
- GitHub Actions, CI matrix, 4 job types, server versions, ASAN leaks -> Build (ci-pipeline)
- Adding commands, Command_JsonXxx, command flags, ACL categories, key-spec -> Contributing (adding-commands)
- Extending JSONPath, adding new parse methods, Token extensions -> JSONPath Engine (selector)
- RDB versioning, DOCUMENT_TYPE_ENCODING_VERSION, backward compat -> Persistence (rdb-format)
- ReplicateVerbatim, PR checklist, coding conventions -> Contributing (adding-commands)
- max-document-size, max-path-limit, HashTable factors -> Cross-Module (cross-module)
- Performance investigation, member lookup, hash table conversion -> Document Model (object-hashtable)
- Memory fragmentation, allocation tracking, per-document stats -> Persistence (defrag)
- v1/v2 reply format differences, legacy path compat -> JSONPath Engine (path-operations)
- Test failures, pytest fixtures, test data setup -> Build (testing)
- CI failures, leak reports, sanitizer output -> Build (ci-pipeline)
- Crash in DOM layer, double-free, use-after-free -> Document Model (memory-layers)
- New JSON.* command implementation -> Contributing (adding-commands)

## Quick Start

    # Build
    ./build.sh                          # Release build -> build/src/libjson.so

    # Run tests
    ./build.sh --unit                   # GoogleTest unit tests
    ./build.sh --integration            # pytest integration tests (builds server)

    # Debug / sanitizer build
    ASAN_BUILD=true ./build.sh --integration

    # Load module
    valkey-server --loadmodule ./build/src/libjson.so

    # Clean
    ./build.sh --clean


## Critical Rules

1. **C++ with jsn:: namespace** - module code uses `jsn::` types; do not mix raw RapidJSON types outside the DOM layer
2. **Three-layer memory** - all allocations flow through memory traps -> dom_alloc -> RapidJsonAllocator; never bypass layers
3. **RDB encoding version** - bump DOCUMENT_TYPE_ENCODING_VERSION when changing persisted format; maintain backward-compat loaders
4. **ReplicateVerbatim** - commands that mutate must call ReplicateVerbatim for AOF/replication correctness
5. **v1/v2 path semantics** - legacy dot-notation (v1) and JSONPath (v2) have different return types; commands must handle both
6. **Tests required** - every change needs GoogleTest unit tests and/or pytest integration tests
7. **ASAN clean** - CI runs ASAN builds; no memory leaks or undefined behavior allowed

## Document Model

| Topic | Reference |
|-------|-----------|
| JDocument/JValue type hierarchy, JParser, RapidJsonAllocator, GenericMember, flags | [jdocument](reference/document/jdocument.md) |
| Object vector vs hash table storage, conversion threshold, GenericMemberHT, linear probing | [object-hashtable](reference/document/object-hashtable.md) |
| KeyTable singleton, shard architecture, PtrWithMetaData, FNV-1a hash, ref counting | [keytable](reference/document/keytable.md) |
| Three-layer memory (traps -> dom_alloc -> RapidJsonAllocator), TLS tracking, stats | [memory-layers](reference/document/memory-layers.md) |

## JSONPath Engine

| Topic | Reference |
|-------|-----------|
| Selector class, Lexer, Token types, v1/v2 path syntax, EBNF grammar, safety limits | [selector](reference/jsonpath/selector.md) |
| Filter expressions `[?(...)]`, comparison/boolean operators, type coercion, partial paths | [expressions](reference/jsonpath/expressions.md) |
| Dot/bracket notation, wildcards, recursive descent, array slicing, unions, DOM mutation mapping | [path-operations](reference/jsonpath/path-operations.md) |

## Persistence and Cross-Module

| Topic | Reference |
|-------|-----------|
| RDB save/load, encoding versions 0 and 3, metacodes, AOF rewrite, data type registration | [rdb-format](reference/persistence/rdb-format.md) |
| Defrag callback, copy-swap strategy, defrag_threshold, defrag stats | [defrag](reference/persistence/defrag.md) |
| SharedJSON_Get, C API functions, CONFIG SET json.*, KeyTable/HashTable tuning | [cross-module](reference/persistence/cross-module.md) |

## Build and Contributing

| Topic | Reference |
|-------|-----------|
| CMake build system, dependencies, compiler flags, SIMD, ASAN, build.sh options | [build](reference/contributing/build.md) |
| GoogleTest unit tests, module_sim stubs, pytest integration tests, test data | [testing](reference/contributing/testing.md) |
| GitHub Actions CI, 4 job types, server version matrix, ASAN leak detection | [ci-pipeline](reference/contributing/ci-pipeline.md) |
| Command handler pattern, registration, ACL, key-spec, v1/v2 paths, PR checklist | [adding-commands](reference/contributing/adding-commands.md) |
