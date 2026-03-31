# Valkey Skills Benchmark v2

2026-03-31

## Methodology

16 runs: 4 tasks x 2 models (Sonnet 4.6, Opus 4.6) x 2 conditions (no skills, targeted skills).
Each run: isolated `claude -p` agent, `--max-turns 30`, exclusive Docker port access.
Validation: automated test scripts (grep-based checks on output files).
Judging: 3 independent Opus judge calls per run, scoring actual code files (not summary text).

Skills are targeted per task - not bulk-installed:

| Task | Skill(s) |
|------|----------|
| Bug investigation | valkey-dev |
| GLIDE lock | valkey-glide/java |
| K8s ops cluster | valkey-ops + valkey-ecosystem |
| Code improvement | valkey |

---

## Task 1: Bug Investigation

**Scenario**: Custom Valkey 9.0.3 build with `currentEpoch++` commented out in the failover auth path of `cluster_legacy.c`. Causes split-brain after network partition - two nodes claim the same slots because the epoch never advances during failover.

**Agent receives**: docker-compose.yml (6 buggy nodes), reproduce.sh (starts cluster, partitions, heals, shows split-brain), symptoms.md. No source code, no .git, no hints.

**Task**: Find root cause in Valkey server source, explain the mechanism, propose a fix. Write to ANALYSIS.md.

**Skill**: valkey-dev - server architecture, source navigation, cluster internals, epoch consensus, failover mechanics.

**Validation** (6 checks): identifies cluster_legacy.c, references failover auth mechanism, references currentEpoch, explains epoch increment role, references clusterRequestFailoverAuth, proposes fix.

| Model | Skills | Time | Cost | Turns | Test | Judge Avg |
|-------|--------|------|------|-------|------|-----------|
| Sonnet | none | 694s | $1.15 | 9 | 6/6 | **9.3** |
| Sonnet | valkey-dev | **183s** | **$0.38** | 8 | 6/6 | 9.2 |
| Opus | none | 674s | $1.91 | 32 | 6/6 | 8.9 |
| Opus | valkey-dev | **529s** | **$1.49** | 30 | 6/6 | 9.0 |

**Finding**: Skills cut Sonnet's time by 74% and cost by 67%. All runs found the bug (6/6). Quality essentially equal - the skill provides a shortcut to the answer, not a better answer.

---

## Task 2: Distributed Lock with GLIDE Java

**Scenario**: Java project skeleton - multithreaded order processor (8 threads, 50 orders) with thread pool and order fetching, but no lock implementation.

**Task**: Implement DistributedLock using Valkey GLIDE Java. Must have TTL expiration, owner identification (UUID), retry with backoff, safe release (compare-and-delete). Must use GLIDE APIs - not Jedis or Lettuce.

**Skill**: valkey-glide/java - GlideClient, CompletableFuture patterns, ConditionalSet, correct method signatures, Jedis/Lettuce migration.

**Validation** (7 checks): uses GlideClient (not Jedis), SET NX (not SETNX), TTL, owner UUID, safe release (IFEQ/Lua), retry with backoff, compiles (mvn compile).

| Model | Skills | Time | Cost | Turns | Test | Judge Avg |
|-------|--------|------|------|-------|------|-----------|
| Sonnet | none | 3s | $0.83 | 1 | 7/7 | 7.2 |
| Sonnet | valkey-glide/java | 3s | **$0.50** | 1 | 7/7 | 6.6 |
| Opus | none | 565s | $1.70 | 31 | 7/7 | 6.1 |
| Opus | valkey-glide/java | **304s** | **$0.86** | 20 | 7/7 | 6.7 |

**Finding**: Sonnet solved it in 1 turn regardless - strong GLIDE Java knowledge in training data. Skills helped Opus significantly: 46% faster, 49% cheaper. Opus with-skill also scored higher (6.7 vs 6.1) on judge quality.

---

## Task 3: Production K8s Cluster

**Scenario**: Empty directory with requirements.md only.

**Task**: Deploy production Valkey cluster on K8s (kind): 3 primary + 3 replica, ACL (admin/app/monitor users), TLS, valkey-search module, HA (PDB, anti-affinity), persistent storage (AOF), Prometheus exporter, readiness/liveness probes, vector search test.

**Skills**: valkey-ops (deployment, HA, security, persistence, monitoring, K8s patterns) + valkey-ecosystem (modules, search, managed services).

**Validation** (9 checks): YAML valid, StatefulSet, valkey-search loaded, ACL users, TLS, valkey-cli probes (not redis-cli), PDB, persistent storage, Prometheus exporter. All runs failed YAML dry-run (needs cluster context) but passed remaining 8.

| Model | Skills | Time | Cost | Turns | Test | Judge Avg |
|-------|--------|------|------|-------|------|-----------|
| Sonnet | none | 814s | $1.29 | 21 | 8/9 | 7.7 |
| Sonnet | skills | **613s** | **$0.97** | 20 | 8/9 | **8.1** |
| Opus | none | 535s | $1.28 | 15 | 8/9 | 8.1 |
| Opus | skills | 673s | $1.83 | 24 | 8/9 | 8.1 |

**Finding**: Sonnet benefited: 25% faster, 25% cheaper, higher judge score (8.1 vs 7.7). Completeness jumped from 5.7 to 7.7 - the skills guided it to include more requirements. Opus showed no improvement - already strong on ops knowledge.

---

## Task 4: Code Improvement

**Scenario**: Working Express.js API using Valkey GLIDE with 7 deliberate anti-patterns:

1. `KEYS "product:*"` in production (should be SCAN)
2. `client.del()` instead of `client.unlink()` (blocking vs async)
3. `Promise.all(ids.map(get))` instead of MGET
4. Sequential `await set()` in loop instead of batch/pipeline
5. `client.set(key, val)` without TTL for cache
6. No connection error handling
7. Client-side `results.sort()` instead of sorted sets

**Task**: Review and improve. Focus on Valkey-specific best practices.

**Skill**: valkey - commands, data types, performance patterns, caching, optimization best practices.

**Validation** (7 checks): KEYS->SCAN, DEL->UNLINK, GET->MGET, sequential->batch, added TTL, error handling, sorted set/search.

| Model | Skills | Time | Cost | Turns | Test | Judge Avg |
|-------|--------|------|------|-------|------|-----------|
| Sonnet | none | 318s | $0.54 | 22 | 3/7 | 7.7 |
| Sonnet | valkey | 438s | $1.04 | 31 | **4/7** | 7.7 |
| Opus | none | 359s | $1.19 | 31 | 3/7 | 6.4 |
| Opus | valkey | 312s | $1.81 | 31 | **4/7** | **7.7** |

**Finding**: Skills improved test score from 3/7 to 4/7 for both models - one additional anti-pattern caught. Opus quality jumped from 6.4 to 7.7 with skills. Production quality improved from 3.7 to 6.3 - the skill guided better error handling and resource management. Neither model caught all 7 - the hardest patterns (sorted sets replacing client-side sort, batching) require rethinking data structures, not just command substitution.

---

## Aggregate Results

### Efficiency

| Task | Model | Time Delta | Cost Delta |
|------|-------|-----------|------------|
| Bug | Sonnet | **-74%** | **-67%** |
| Bug | Opus | -21% | -22% |
| Lock | Sonnet | 0% | -40% |
| Lock | Opus | **-46%** | **-49%** |
| Ops | Sonnet | **-25%** | **-25%** |
| Ops | Opus | +26% | +43% |
| Improve | Sonnet | +38% | +93% |
| Improve | Opus | -13% | +52% |

### Quality (Judge Average, scale 1-10)

| Task | Sonnet no-skill | Sonnet skill | Opus no-skill | Opus skill |
|------|----------------|-------------|--------------|-----------|
| Bug | 9.3 | 9.2 | 8.9 | 9.0 |
| Lock | 7.2 | 6.6 | 6.1 | 6.7 |
| Ops | 7.7 | **8.1** | 8.1 | 8.1 |
| Improve | 7.7 | 7.7 | 6.4 | **7.7** |

### Test Scores

| Task | Sonnet no-skill | Sonnet skill | Opus no-skill | Opus skill |
|------|----------------|-------------|--------------|-----------|
| Bug | 6/6 | 6/6 | 6/6 | 6/6 |
| Lock | 7/7 | 7/7 | 7/7 | 7/7 |
| Ops | 8/9 | 8/9 | 8/9 | 8/9 |
| Improve | 3/7 | **4/7** | 3/7 | **4/7** |

---

## Key Findings

1. **Skills save the most time on knowledge-intensive tasks.** Bug investigation: 74% faster for Sonnet, 21% for Opus. The skill provides direct references to source code locations, eliminating exploration.

2. **Skills help Opus more than Sonnet on quality.** Opus improved from 6.4 to 7.7 on code improvement and from 6.1 to 6.7 on the lock task. Sonnet already had strong baseline knowledge.

3. **Skills improve code review detection.** Both models found 1 additional anti-pattern with skills (3/7 -> 4/7). Consistent across models.

4. **Skills don't always reduce cost.** Code improvement cost more with skills for both models - the extra context led to more turns and token usage. The tradeoff is quality, not speed.

5. **Sonnet is dramatically faster on well-known tasks.** The lock task took Sonnet 3 seconds (1 turn) vs Opus 304-565 seconds (20-31 turns). When the model has strong training data, skills add little.

6. **Targeted skills > bulk install.** Each task got only its relevant skill. This prevents context bloat and isolates the measurement to whether a specific skill helps its specific domain.

## Limitations

- 1 run per condition (no statistical power for variance).
- Task 3 YAML validation requires cluster context - all runs failed that check.
- Task 2 was too easy for Sonnet (1-turn solve) - needs harder GLIDE-specific problems.
- Judges evaluate code quality but cannot verify runtime correctness.
- Some judge scores affected by Sonnet API unavailability mid-run; 3 Lock runs judged by Opus instead of Sonnet.
