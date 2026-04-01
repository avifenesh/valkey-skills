---
name: valkey-bloom-dev
description: "Use when contributing to valkey-io/valkey-bloom source - Rust bloom filter internals, building, testing, RDB/AOF, replication, or reviewing PRs. Not for using BF commands in apps (valkey-modules) or building new modules (valkey-module-dev)."
version: 1.0.0
argument-hint: "[area or task]"
---

# Valkey Bloom Module - Contributor Reference

## Not This Skill

- Using BF.ADD/BF.EXISTS/BF.RESERVE in applications -> use valkey-modules
- Building custom Valkey modules from scratch -> use valkey-module-dev
- valkey-module Rust SDK reference -> use valkey-module-dev

## Routing

- BloomObject struct, scaling, sub-filters, tightening ratio, fp_rate, expansion, VALIDATESCALETO -> Architecture (bloom-object)
- BloomFilter struct, bloomfilter crate, seed handling, random vs fixed, item add/check -> Architecture (bloom-filter)
- RDB save/load, AOF rewrite, bincode serialization, BF.LOAD encoding, copy callback -> Architecture (persistence)
- Defrag callbacks, cursor-based defrag, INFO bf metrics, atomic counters -> Architecture (defrag-metrics)
- Memory layout, SipHash, memory limit, validate_size, bloom-memory-usage-limit -> Architecture (bloom-object)
- Module initialization, valid_server_version, HANDLE_IO_ERRORS -> Architecture (bloom-object)
- BF.ADD, BF.MADD, BF.EXISTS, BF.MEXISTS, BF.CARD, BF.INFO, auto-creation -> Commands (command-handlers)
- BF.INFO field queries: CAPACITY, SIZE, FILTERS, ITEMS, ERROR, EXPANSION -> Commands (command-handlers)
- BF.RESERVE, BF.INSERT, BF.LOAD, NOCREATE, argument parsing -> Commands (bf-reserve-insert)
- TIGHTENING/SEED as replication-only args, BF.LOAD deserialization, BUSYKEY -> Commands (bf-reserve-insert)
- Replication strategy, ReplicateArgs, reserve vs add-only, deterministic replication -> Commands (replication)
- must_obey_client, valkey_8_0 feature, 8.0 vs 8.1 compat, size limit bypass -> Commands (replication)
- Keyspace notifications, bloom.add, bloom.reserve, replicate_verbatim -> Commands (replication)
- bloom-memory-usage-limit, bloom-capacity, bloom-expansion, bloom-defrag-enabled -> Commands (module-configs)
- bloom-fp-rate, bloom-tightening-ratio, on_string_config_set, string->f64 validation -> Commands (module-configs)
- bloom-use-random-seed, FIXED_SEED, module_args_as_configuration -> Commands (module-configs)
- Cargo build, feature flags, clippy, cdylib, ValkeyAlloc, build.sh -> Contributing (build)
- Unit tests, rstest, parameterized tests, cargo test -> Contributing (testing)
- Python integration tests, pytest, valkey-test-framework, conftest -> Contributing (testing)
- CI pipeline, GitHub Actions, build-ubuntu, build-macos, asan-build -> Contributing (ci-pipeline)
- ASAN, LeakSanitizer, skip_for_asan, sanitizer detection -> Contributing (ci-pipeline)
- Code structure, adding commands, command_handler.rs, data_type.rs, directory layout -> Contributing (code-structure)
- ACL category, BloomError, command metadata JSON, module registration -> Contributing (code-structure)

## Quick Start

```bash
# Build for Valkey >= 8.1
cargo build --release

# Build for Valkey 8.0
cargo build --release --features valkey_8_0

# Unit tests (requires system allocator)
cargo test --features enable-system-alloc

# Load into Valkey
valkey-server --loadmodule ./target/release/libvalkey_bloom.so

# Integration tests (requires running Valkey with module loaded)
python3 -m pytest tests/ -v
```

Commands: BF.ADD, BF.MADD, BF.EXISTS, BF.MEXISTS, BF.CARD, BF.RESERVE, BF.INFO, BF.INSERT, BF.LOAD

## Critical Rules

1. **ValkeyAlloc is the global allocator** - the module uses `#[global_allocator]` with ValkeyAlloc so Valkey tracks all memory; unit tests need `--features enable-system-alloc` to swap in the system allocator
2. **Seeds must be deterministic for replication** - BF.INSERT sends SEED and TIGHTENING as replication-only arguments to ensure replicas build identical filters
3. **Respect bloom-memory-usage-limit** - size validation via `validate_size` must pass before creating or scaling; replicas bypass via `must_obey_client`
4. **Feature flag for 8.0 compat** - `--features valkey_8_0` gates APIs unavailable on Valkey 8.0 (e.g., keyspace notifications)
5. **Tests are non-negotiable** - unit tests via rstest + cargo test, integration tests via pytest with valkey-test-framework
6. **CI runs ASAN builds** - address sanitizer catches memory issues; use `skip_for_asan` for tests incompatible with leak detection

## Architecture

| Topic | Reference |
|-------|-----------|
| BloomObject struct, scaling mechanism, FP tightening, memory limits, VALIDATESCALETO | [bloom-object](reference/architecture/bloom-object.md) |
| BloomFilter struct, bloomfilter crate, seed handling, item add/check flow | [bloom-filter](reference/architecture/bloom-filter.md) |
| RDB save/load, AOF rewrite, bincode encode/decode, copy callback, data type registration | [persistence](reference/architecture/persistence.md) |
| Defrag callbacks, cursor-based incremental defrag, INFO bf metrics, atomic counters | [defrag-metrics](reference/architecture/defrag-metrics.md) |

## Commands and Replication

| Topic | Reference |
|-------|-----------|
| BF.ADD, BF.MADD, BF.EXISTS, BF.MEXISTS, BF.CARD, BF.INFO handlers | [command-handlers](reference/commands/command-handlers.md) |
| BF.RESERVE, BF.INSERT, BF.LOAD, NOCREATE, VALIDATESCALETO, replication args | [bf-reserve-insert](reference/commands/bf-reserve-insert.md) |
| Deterministic replication, must_obey_client, keyspace notifications | [replication](reference/commands/replication.md) |
| All 7 configs, defaults, ranges, on_string_config_set, module_args_as_configuration | [module-configs](reference/commands/module-configs.md) |

## Build and Contributing

| Topic | Reference |
|-------|-----------|
| Cargo.toml, cdylib, dependencies, feature flags, ValkeyAlloc, build.sh | [build](reference/contributing/build.md) |
| Unit tests (rstest, parameterized), integration test framework, test helpers | [testing](reference/contributing/testing.md) |
| GitHub Actions CI jobs, matrix versions, ASAN/LeakSanitizer, release workflow | [ci-pipeline](reference/contributing/ci-pipeline.md) |
| Directory layout, module registration, command metadata JSON, error types, adding new commands | [code-structure](reference/contributing/code-structure.md) |
