---
name: valkey-json-dev
description: "Use when contributing to the valkey-json module codebase, understanding its architecture, building from source, running tests, adding commands, extending the JSONPath engine, debugging RDB serialization, or reviewing PRs in valkey-io/valkey-json."
version: 1.0.0
argument-hint: "[area or task]"
---

# Valkey JSON Module Development Reference

C++ module development reference for contributors to valkey-io/valkey-json.

## Routing

- Document model, JDocument, JValue, RapidJSON, KeyTable, memory layout -> Architecture
- Build from source, unit tests, integration tests, ASAN, CI -> Build and Test
- Code structure, adding commands, adding JSONPath features, RDB versioning -> Contributing

## Reference

| Topic | Reference |
|-------|-----------|
| Document model, JSONPath engine, memory layout, RDB serialization, KeyTable | [architecture](reference/architecture.md) |
| Build system, unit tests, integration tests, ASAN, CI matrix | [build-and-test](reference/build-and-test.md) |
| Code structure, adding commands, extending JSONPath, coding conventions | [contributing](reference/contributing.md) |

## Quick Orientation

```
src/json/json.cc       - Module entry, command handlers, RDB callbacks, config
src/json/dom.cc/.h     - Document model, CRUD, parse, serialize, RDB save/load
src/json/selector.cc/.h - JSONPath parser and evaluator (v1 legacy + v2 dollar)
src/json/keytable.cc/.h - Shared string interning table (ref-counted, sharded)
src/json/alloc.cc/.h   - DOM allocator wrapping ValkeyModule_Alloc
src/json/stats.cc/.h   - Memory tracking, histograms, info metrics
src/json/memory.cc/.h  - Memory traps, custom STL allocator (jsn:: namespace)
src/json/util.cc/.h    - Error codes, number formatting, overflow checks
src/json/json_api.cc/.h - C API for cross-module access
src/json/shared_api.cc/.h - SharedJSON_Get for other modules
src/rapidjson/         - Vendored RapidJSON (modified headers)
```
