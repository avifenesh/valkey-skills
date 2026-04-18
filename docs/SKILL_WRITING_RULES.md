# Skill-writing rules (accumulated from validation passes)

Rules learned while validating valkey, valkey-dev, valkey-ops, valkey-bloom-dev, valkey-search-dev, and glide-dev against source. Apply to every skill edit in this repo.

## Audience: agents already trained on the ecosystem baseline

A trained LLM already knows standard Redis/Valkey structures, stock RESP, stock cmake, `processCommand -> call -> cmd->proc`, jemalloc defaults. Same for Rust/Cargo basics, PyO3/NAPI/JNI mechanics, standard Tokio runtime patterns. Restating these burns context.

Only write:

1. **Divergence** - where this component behaves differently from the baseline an agent already knows.
2. **Novel subsystems** - net-new files, ABIs, or mechanisms that don't exist in the baseline.
3. **Non-obvious invariants / gotchas** - ownership rules, aliasing, hidden state, pausepoint discipline.
4. **Non-standard pieces** - JSON-generated code, TCL-plus-sanitizer test frameworks, vendored forks.

POC test before writing any line: "would a trained agent know this if asked?" If yes, cut.

## Cut without regret

- File maps of standard subsystems (agent already knows `src/ae.c` is the reactor)
- Overview files that just redirect to other files - fold pointers into SKILL.md router
- "Standard X, same as Redis" framing - if it's the same, drop the topic entirely
- Code snippets agents can read from struct definitions themselves
- Marketing numbers ("40% faster", "1B RPS") unless source-verifiable
- Version annotations like `(Valkey 8.0+)` when the baseline is `unstable` - they decay
- "Renamed from X" history - agents need the current name, not the rename story
- Version-history tables in reference docs - decay-prone, not actionable
- "Contents" / TOC blocks at the top of merged files - agents grep `## Heading` directly

## Paths and symbols, not line numbers

Line numbers drift on every edit. Always prefer path + function name or unique grep string.

Write `src/rdb.c` with the function name. Avoid `file:lineno`, `file:a-b`, or `(line N)` in headings.

## Grep-hazards block is the highest-leverage content

Renamed symbols, vendored-vs-native code, module-name vs type-name confusion - this is the single most valuable content in a contributor skill. Every SKILL.md should carry a "grep hazards" section. Examples proven valuable:

- valkey-search-dev: module `"search"` vs dummy type `"Vk-Search"`, `kCoordinatorPortOffset=20294`, `FT._DEBUG` off unless in debug mode
- valkey-bloom-dev: module `bf` vs ACL `bloom` vs type `bloomfltr`, `BLOOM_OBJECT_VERSION` vs `BLOOM_TYPE_ENCODING_VERSION`, Vec-defrag counter bug
- valkey-dev: `events-per-io-thread` deprecation, dict-is-now-hashtable
- glide-dev: multiplexer-not-pool, cluster-not-pool-of-standalones, `glide-core/redis-rs/` is vendored-not-GLIDE, UDS is in-process IPC

## Always run two validation passes

One pass catches ~60% of factual errors. A second pass with a narrower correctness lens catches the rest. Real examples caught only on pass 2:

- valkey-search-dev pass 2: `coordinator-query-timeout-secs` default was 25 in skill, actual is 120
- valkey-search-dev pass 2: `hnsw-allow-replace-deleted` config doesn't exist on 1.2.0 (TODO in source, hardcoded false)
- glide-dev pass 2: Java `process_command_for_compression` duplicate (fabrication); retry-field `retryServerError`/`retryConnectionError` was camelCase wrapper-API name in a section describing the Rust core struct

**Pass-2 pattern for config tables:** every config must be verified to exist as a real `config::*Builder` registration (or equivalent per-ecosystem), not just referenced in code or TODO comments. Run `git grep -nE '"<config-name>"' <tag> -- src/` and require a real registration hit.

## Baseline targeting per skill

- `valkey` (app-dev): 9.0.3 - stable reference for users building apps
- `valkey-dev` (contributor): `origin/unstable` - what contributors actually touch
- `valkey-ops`: 9.0.3 (operator perspective)
- `valkey-bloom-dev`: tag `1.0.1`
- `valkey-search-dev`: tag `1.2.0`
- `glide-dev`: tag `v2.3.1` (GLIDE cuts unified tags across languages; `-java`-suffixed tags are supplementary Java-only releases)
- Per-language GLIDE skills: baseline 2.3.1
- Spring Data Valkey: 1.0
- If unclear, ask

When working on the `unstable` baseline, stop adding version annotations - they decay. Describe CURRENT behavior.

## When a fabrication turns up, fix at the source

If validating surfaces a fabrication from an earlier session (e.g., hash-tag co-location claim, pool-language creep), correct the skill file immediately and add the caught pattern to `memory/valkey_fabrications_caught.md` as a regression guard for future passes. Don't assume later prompts caught it.

## Don't commit to version specifics that may shift

For fast-moving components (GLIDE in particular), describe capabilities conceptually or link to the repo. Avoid "GLIDE 2.x does X" unless the specific release IS the point of the section.

## GLIDE-specific correctness rules

Captured from maintainer corrections. These recur because agents pattern-match from typical clients (jedis, redis-py, node-redis) that work differently.

1. **GLIDE is a multiplexer.** One multiplexed connection, many in-flight requests tagged with IDs. Always write "multiplexer" when describing the core client. Call the concurrency cap "inflight limit" (`DEFAULT_MAX_INFLIGHT_REQUESTS = 1000`), not "pool size". Avoid "connection pool", "pool of clients", "checkout connection" for the core.

2. **Cluster client and standalone client are two distinct implementations.** Keep them separate in prose. `ClientWrapper` is an enum with separate variants (`Standalone(StandaloneClient)` vs `Cluster { client: ClusterConnection }`). Describe each with its own state machine, routing, and reconnection logic. Cluster is NOT "a pool of standalones" or "a wrapper around standalone".

3. **UDS is in-process IPC.** Python-async and Node bindings pass messages between the language layer and the Rust core over a Unix domain socket within the same process. Always say "in-process" when describing UDS. The Rust core is not a separate process; no network hop.

4. **Two client categories by FFI mechanism:**
   - UDS clients: Python async, Node.js (in-process message passing)
   - FFI clients: Python sync, Go, Java (JNI), PHP, C#, Ruby (direct C ABI calls)

5. **`glide-core/redis-rs/` is vendored redis-rs - treat as inheritance, not GLIDE.** Lots of code there is not wired. Always trace call graphs from `glide-core/src/**` outward before attributing behavior. `glide-core/src/client/` holds the real GLIDE client code (`mod.rs`, `standalone_client.rs`, `reconnecting_connection.rs`). Avoid claims that `glide-core/redis-rs/**` "is GLIDE".

6. **Cross-language blast radius.** A change in `glide-core/` or `ffi/` affects all language bindings AND both FFI modes. Before recommending a core change, walk through impact on: UDS path, FFI path, each language wrapper, each language's tests. List the languages affected explicitly.

7. **HA/reliability and performance are both top priorities - never risk either.** HA/reliability is arbitrated first when tradeoffs force a choice, but performance is not secondary. Every core change must be measured and validated for both. Block any change that regresses reconnect/failover behavior OR throughput/latency. An "optimization" that reduces reliability is a regression - and a reliability change that silently tanks throughput is also a regression.
