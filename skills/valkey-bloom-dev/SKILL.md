---
name: valkey-bloom-dev
description: "Use when contributing to valkey-io/valkey-bloom, understanding its scalable bloom filter architecture, building from source, writing tests, adding commands, or reviewing PRs in the valkey-bloom repo."
version: 1.0.0
argument-hint: "[subsystem or task]"
---

# Valkey Bloom Module - Contributor Reference

Rust-based Valkey module implementing scalable bloom filters using the `bloomfilter` crate and `valkey-module` SDK.

## Routing

- Architecture, BloomObject, BloomFilter, scaling, memory layout -> Architecture
- Building, cargo, feature flags, clippy, unit tests, integration tests -> Build & Test
- Adding commands, code structure, Rust module patterns, configs -> Contributing

## Reference

| Topic | Reference |
|-------|-----------|
| Scalable bloom filter design, memory layout, hash functions, tightening ratio | [architecture](reference/architecture.md) |
| Cargo build, feature flags, unit tests, Python integration tests, CI | [build-and-test](reference/build-and-test.md) |
| Code structure, adding commands, module configs, replication, Rust patterns | [contributing](reference/contributing.md) |

## Quick Start

```bash
# Build for Valkey >= 8.1
cargo build --release

# Build for Valkey 8.0
cargo build --release --features valkey_8_0

# Run unit tests
cargo test --features enable-system-alloc

# Load into Valkey
valkey-server --loadmodule ./target/release/libvalkey_bloom.so
```

## Commands

| Command | Flags | Handler |
|---------|-------|---------|
| BF.ADD | write fast deny-oom | `bloom_filter_add_value` |
| BF.MADD | write fast deny-oom | `bloom_filter_add_value` (multi) |
| BF.EXISTS | readonly fast | `bloom_filter_exists` |
| BF.MEXISTS | readonly fast | `bloom_filter_exists` (multi) |
| BF.CARD | readonly fast | `bloom_filter_card` |
| BF.RESERVE | write fast deny-oom | `bloom_filter_reserve` |
| BF.INFO | readonly fast | `bloom_filter_info` |
| BF.INSERT | write fast deny-oom | `bloom_filter_insert` |
| BF.LOAD | write deny-oom | `bloom_filter_load` |
