---
name: valkey-bloom-dev
description: "Use when contributing to valkey-io/valkey-bloom source - Rust bloom filter internals, building, testing, RDB/AOF, replication, or reviewing PRs. Not for using BF.ADD/EXISTS in apps (valkey-modules) or building new modules (valkey-module-dev)."
version: 1.0.0
argument-hint: "[area or task]"
---

# Valkey Bloom Module - Contributor Reference

Rust-based Valkey module implementing scalable bloom filters using the `bloomfilter` crate and `valkey-module` SDK.

## Not This Skill

- Using BF.ADD/BF.EXISTS/BF.RESERVE commands in applications -> use valkey-modules
- Building custom Valkey modules from scratch -> use valkey-module-dev
- valkey-module Rust SDK reference -> use valkey-module-dev

## Routing

- BloomObject, BloomFilter, scaling, tightening ratio, fp_rate, memory layout, SipHash, seed modes -> Architecture
- RDB persistence, AOF rewrite, BF.LOAD encoding, bincode serialization, defrag callbacks -> Architecture
- bloom-memory-usage-limit, bloom-capacity, bloom-expansion, bloom-defrag-enabled, module configs -> Architecture
- Metrics, INFO bf, bloom_num_objects, bloom_total_memory_bytes -> Architecture
- Cargo build, feature flags, clippy, enable-system-alloc, unit tests, rstest -> Build and Test
- Python integration tests, pytest, valkey-test-framework, conftest, ASAN, CI pipeline -> Build and Test
- Code structure, adding commands, command_handler.rs, data_type.rs, utils.rs -> Contributing
- Replication strategy, ReplicateArgs, BF.INSERT SEED, replicate_verbatim -> Contributing
- Keyspace notifications, ACL category, BloomError, valkey_8_0 feature, 8.0 vs 8.1 compat -> Contributing

## Reference

| Topic | Reference |
|-------|-----------|
| BloomObject/BloomFilter structs, scaling, memory layout, RDB/AOF, defrag, metrics, configs | [architecture](reference/architecture.md) |
| Cargo build, feature flags, unit tests, Python integration tests, ASAN, CI matrix | [build-and-test](reference/build-and-test.md) |
| Code structure, adding commands, replication, keyspace events, data type callbacks, errors | [contributing](reference/contributing.md) |

## Quick Reference

```bash
cargo build --release                          # Valkey >= 8.1
cargo build --release --features valkey_8_0    # Valkey 8.0
cargo test --features enable-system-alloc      # Unit tests
valkey-server --loadmodule ./target/release/libvalkey_bloom.so
```

Commands: BF.ADD, BF.MADD, BF.EXISTS, BF.MEXISTS, BF.CARD, BF.RESERVE, BF.INFO, BF.INSERT, BF.LOAD
