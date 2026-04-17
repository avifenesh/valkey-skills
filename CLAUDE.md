# valkey-skills

> Domain-specific AI skills for the Valkey ecosystem - application development, server internals, operations, GLIDE client (7 languages), and module contributor skills

## Skills

### Valkey Core (6 skills)

| Directory | Skill | Audience | Files |
|-----------|-------|----------|-------|
| `skills/valkey/` | valkey | Application developers - Valkey-specific features, patterns, best practices | 41 |
| `skills/valkey-dev/` | valkey-dev | Valkey server contributors | 65 |
| `skills/valkey-ops/` | valkey-ops | Self-hosted Valkey operators | 61 |
| `skills/glide-dev/` | glide-dev | GLIDE client library contributors - Rust core, language bindings, build system | 7 |
| `skills/valkey-search-dev/` | valkey-search-dev | valkey-search module contributors - C++ architecture, index types, query engine, build | 21 |
| `skills/valkey-bloom-dev/` | valkey-bloom-dev | valkey-bloom module contributors - Rust scalable bloom filters, build, replication | 13 |

### GLIDE Per-Language (7 skills)

| Directory | Skill | Content |
|-----------|-------|---------|
| `skills/valkey-glide-python/` | valkey-glide-python | Async/sync API, all data types, OTel, TLS, batching, PubSub, streams |
| `skills/valkey-glide-java/` | valkey-glide-java | CompletableFuture API, configuration builders, batching, streams, server modules |
| `skills/valkey-glide-nodejs/` | valkey-glide-nodejs | Promise API, TypeScript, ESM/CJS, batching, PubSub, streams |
| `skills/valkey-glide-go/` | valkey-glide-go | Synchronous API, CGO, Result[T], batching, error handling |
| `skills/valkey-glide-csharp/` | valkey-glide-csharp | Async/await API, .NET 8.0+ (preview), configuration builders |
| `skills/valkey-glide-php/` | valkey-glide-php | C extension (PHP 8.1+), PIE/Composer/PECL |
| `skills/valkey-glide-ruby/` | valkey-glide-ruby | valkey-rb gem (GA), redis-rb drop-in replacement |

### Migration Skills (6 standalone + 1 framework)

| Directory | Skill | Content | Files |
|-----------|-------|---------|-------|
| `skills/migrate-jedis/` | migrate-jedis | Jedis to GLIDE Java migration | 3 |
| `skills/migrate-lettuce/` | migrate-lettuce | Lettuce to GLIDE Java migration | 3 |
| `skills/migrate-ioredis/` | migrate-ioredis | ioredis to GLIDE Node.js migration | 3 |
| `skills/migrate-redis-py/` | migrate-redis-py | redis-py to GLIDE Python migration | 3 |
| `skills/migrate-go-redis/` | migrate-go-redis | go-redis to GLIDE Go migration | 3 |
| `skills/migrate-stackexchange/` | migrate-stackexchange | StackExchange.Redis to GLIDE C# migration | 3 |
| `skills/spring-data-valkey/` | spring-data-valkey | Spring Boot + Spring Data Valkey integration | 3 |

### Glide-MQ (3 skills, vendored from upstream)

`skills/glide-mq/`, `skills/glide-mq-migrate-bullmq/`, `skills/glide-mq-migrate-bee/`. SKILL.md + `references/*` vendored from [avifenesh/glide-mq](https://github.com/avifenesh/glide-mq) by `scripts/sync-glide-mq-upstream.sh`; pin in `UPSTREAM-GLIDE-MQ.md`. `.github/workflows/sync-glide-mq.yml` runs weekly and opens a PR on drift; `version-watch.yml` tracks version bumps separately.

## Architecture

Each skill is a self-contained installable plugin under `skills/<name>/`:
- `.claude-plugin/plugin.json` - plugin metadata (name, version, description)
- `skills/<name>/SKILL.md` - concise router (<250 lines) with trigger phrases and reference tables
- `skills/<name>/reference/` - deep RAG library of focused docs (each under 300 lines)

Per-language GLIDE skills (Python, Java, Node.js, Go have 9 files; C#, PHP, Ruby have 4 files) are fully language-specific - each contains its own complete API reference, patterns, and examples with no shared reference files. Migration skills each have 2 reference files (api-mapping and advanced-patterns).

The AI loads SKILL.md into context, scans the tables, and reads only the specific reference file needed. No context bloat.

## Installation

Users add the marketplace once, then install individual skills:
```
/plugin marketplace add avifenesh/valkey-skills
/plugin install valkey@valkey-skills
/plugin install valkey-glide-python@valkey-skills
```

The repo also installs as an all-in-one plugin for users who want everything.

## Dev Commands

Skills-only plugin - no build step, no runtime code. `npm test` exits with a message.

## Editing Skills

- New reference docs go in the relevant `skills/{skill}/skills/{skill}/reference/` subdirectory
- Reference directories are flat - place new files directly in reference/ with a descriptive prefix matching the SKILL.md table grouping (e.g., patterns-caching-strategies.md, architecture-overview.md)
- Keep reference files focused on one topic, under 300 lines when possible
- Start each reference doc with a "Use when" trigger line
- Update the SKILL.md router table to include the new file

## Version Baseline

Skills were written and verified against these versions. Update when new releases ship.

| Component | Version | Skills Affected |
|-----------|---------|----------------|
| Valkey server | 9.0.3 | valkey, valkey-dev, valkey-ops |
| Valkey GLIDE | 2.3.1 | valkey-glide, all per-language skills |
| valkey-search | 1.2.0 | valkey-search-dev |
| valkey-json | GA | (reference only) |
| valkey-bloom | GA | valkey-bloom-dev |
| Valkey GLIDE (source) | 2.3.1 | glide-dev |
| Spring Data Valkey | 1.0 | spring-data-valkey |

Last full review: 2026-04-11

## Critical Rules

1. **Plain text output** - No emojis, no ASCII art.
2. **Source-verified** - Reference docs must be verified against actual source code, not just web research.
3. **No unnecessary files** - Don't create summary files, plan files, audit files, or temp docs.
4. **Use single dash for em-dashes** - In prose, use ` - ` (single dash with spaces), never ` -- `.

## Skill-Writing Rules (accumulated from validation passes)

These rules were learned while validating valkey, valkey-dev, valkey-ops, valkey-bloom-dev, valkey-search-dev, and glide-dev against source. Apply to every skill edit in this repo.

### Audience: agents already trained on the ecosystem baseline

An LLM trained on public Redis/Valkey source already knows standard structures, stock RESP, stock cmake, `processCommand → call → cmd->proc`, jemalloc defaults, etc. Same for Rust/Cargo basics, PyO3/NAPI/JNI mechanics, standard Tokio runtime patterns. Restating these burns context. Only keep:

1. **Divergence** - where this component behaves differently from the baseline an agent already knows.
2. **Novel subsystems** - net-new files, ABIs, or mechanisms that don't exist in the baseline.
3. **Non-obvious invariants / gotchas** - ownership rules, aliasing, hidden state, pausepoint discipline.
4. **Non-standard pieces** - JSON-generated code, TCL-plus-sanitizer test frameworks, vendored forks.

POC test before writing any line: "would a trained agent know this if asked?" If yes, cut.

### Cut these without regret

- File maps of standard subsystems (agent already knows `src/ae.c` is the reactor)
- Overview files that just redirect to other files - fold pointers into SKILL.md router
- "Standard X, same as Redis" framing - if it's the same, delete the topic entirely
- Code snippets agents can read from struct definitions themselves
- Marketing numbers ("40% faster", "1B RPS", "4.6x speedup") unless source-verifiable
- Version annotations like `(Valkey 8.0+)` when the baseline is `unstable` - they decay
- "Renamed from X" history - agents don't need the rename story, just the current name
- Version-history tables inside reference docs - decay-prone, not actionable for contributors
- "Contents" / TOC blocks at the top of merged files - agents grep `## Heading` directly

### No line-number citations

Line numbers drift on every edit. Path + symbol/function name stays stable.

- Write `src/rdb.c` with function name or unique grep string
- Never `file:lineno`, `file:a-b`, or `(line N)` in headings

### Grep-hazards block is the highest-leverage content

Renamed symbols, vendored-vs-native code, module-name-vs-type-name confusion are the single most valuable content in a contributor skill. Maintain a "grep hazards" section in every SKILL.md. Examples proven valuable:

- valkey-search-dev: module `"search"` vs dummy type `"Vk-Search"`, `kCoordinatorPortOffset=20294`, `FT._DEBUG` off unless in debug mode
- valkey-bloom-dev: module `bf` vs ACL `bloom` vs type `bloomfltr`, `BLOOM_OBJECT_VERSION` vs `BLOOM_TYPE_ENCODING_VERSION`, Vec-defrag counter bug
- valkey-dev: `events-per-io-thread` deprecation, dict-is-now-hashtable
- glide-dev: multiplexer-not-pool, cluster-not-pool-of-standalones, `glide-core/redis-rs/` is vendored-not-GLIDE, UDS is in-process IPC

### Validation: always run two passes

One pass catches ~60% of factual errors. Second pass with a narrower correctness lens catches the rest. Real examples of bugs only caught on pass 2:

- valkey-search-dev pass 2: `coordinator-query-timeout-secs` default was 25 in skill, actual is 120
- valkey-search-dev pass 2: `hnsw-allow-replace-deleted` config doesn't exist on 1.2.0 (TODO in source, hardcoded false)

**Pass-2 pattern for config tables:** every config must be verified to exist as a real `config::*Builder` registration (or equivalent per-ecosystem), not just referenced in code or TODO comments. `git grep -nE '"<config-name>"' <tag> -- src/` must return a real registration.

### Baseline targeting per skill

- `valkey` (app-dev): 9.0.3 - stable reference for users building apps
- `valkey-dev` (contributor): `origin/unstable` - what contributors actually touch
- `valkey-ops`: 9.0.3 (operator perspective)
- `valkey-bloom-dev`: tag `1.0.1`
- `valkey-search-dev`: tag `1.2.0`
- `glide-dev`: tag `v2.3.1` (GLIDE cuts unified tags across languages; `-java`-suffixed tags are supplementary Java-only releases)
- Per-language GLIDE skills: baseline 2.3.1
- Spring Data Valkey: 1.0
- If unclear, ask

When working on the `unstable` baseline, stop adding version annotations - they will decay. The CURRENT BEHAVIOR is what matters.

### When caught faking, stop and fix

If validating turns up a fabrication introduced earlier in the session (e.g., hash-tag co-location claim, pool-language creep), fix it at the source before continuing. Don't assume the downstream prompt caught it. Add the caught fabrication to `memory/valkey_fabrications_caught.md` as a regression guard for future passes.

### Don't commit to version specifics that may shift

For fast-moving components (GLIDE in particular), describe capabilities conceptually or link to the repo. Don't say "GLIDE 2.x does X" unless the specific release IS the point of the section.

### GLIDE-specific correctness rules (for glide-dev and per-language skills)

Captured from maintainer corrections. These mistakes recur because agents pattern-match from typical clients (jedis, redis-py, node-redis) that work differently.

1. **GLIDE is a multiplexer, not a connection pool.** One multiplexed connection, many in-flight requests tagged with IDs. Never say "pool size", "connection pool", "checkout connection" about the core client. If a skill says "pool" referring to the core, that's a bug.

2. **Cluster client and standalone client are two different animals.** Not one wrapping the other, not a pool of standalones. Distinct implementations with different state machines, routing, and reconnection. `ClientWrapper` is an enum with separate variants, not a wrapper hierarchy.

3. **UDS is in-process IPC, not network.** Python-async and Node bindings use a Unix domain socket for message passing between the language layer and the Rust core **within the same process**. Not a remote connection, no network hop, Rust core is not a separate process.

4. **Two client categories by FFI mechanism:**
   - **UDS clients**: Python async, Node.js (in-process message passing)
   - **FFI clients**: Python sync, Go, Java (JNI), PHP, C#, Ruby (direct C ABI calls)

5. **`glide-core/redis-rs/` is vendored redis-rs - treat as inheritance, not GLIDE.** Lots of code there is not wired. Before claiming "the core does X" based on reading a function in `glide-core/redis-rs/**`, verify the call graph from `glide-core/src/**` outward. `glide-core/src/client/` is the real GLIDE client code (`standalone_client.rs` + `reconnecting_connection.rs` + the wrapper in `mod.rs`).

6. **Cross-language blast radius.** A change in `glide-core/` or `ffi/` affects ALL language bindings AND both FFI modes. Before recommending a core change, think through impact on UDS path, FFI path, each language wrapper, each language's test suite.

7. **HA/reliability and performance are both top priorities - never risk either.** HA/reliability is arbitrated first when tradeoffs force a choice, but performance is not "secondary". Every core change must be measured and validated for both. No change ships if it regresses reconnect/failover behavior OR throughput/latency. An "optimization" that reduces reliability in any reconnect/failover scenario is not an optimization - and a reliability change that silently tanks throughput is also a regression.
