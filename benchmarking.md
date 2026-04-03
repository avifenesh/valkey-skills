# Valkey Skills Benchmark Results

Benchmark measuring whether AI agent skills improve task completion quality and efficiency. Each task runs with and without skills loaded. Results are median of 3 runs (Sonnet) or 2 runs (Opus).

**Models**: Claude Sonnet 4.6, Claude Opus 4.6 (Bedrock)
**Method**: Isolated workspaces, no web access, no shared context. Skills loaded via `.claude/skills/` directory.

## Skill Wins

### valkey (application developer skill)

**Task: Problem-solving questions requiring Valkey 9.x knowledge**

10 real-world scenarios - diagnosing slow commands, implementing feature flags, per-field session TTLs, distributed lock release, config migration from Redis 7.2, replication debugging, I/O thread tuning, multi-database clustering, cluster-wide key iteration.

| Model | Without Skill | With Skill | Improvement |
|-------|--------------|------------|-------------|
| Sonnet 4.6 | 6/14 | **10/14** | +4 checks. Skill taught COMMANDLOG (not SLOWLOG), SET IFEQ, HSETEX/HGETEX for per-field TTL, DELIFEQ for lock release, lazyfree default changes, CLUSTERSCAN. Without skills, model used Redis 7.x answers. |
| Opus 4.6 | 5/14 | **10/14** | +5 checks. Same pattern - Opus defaulted to Redis approaches without the skill. |

### valkey-ops (operations skill)

**Task: Helm chart setup for Valkey cluster on Kubernetes**

Create a complete Helm values file, setup script, and README for deploying a 6-node Valkey cluster with TLS, auth, persistence, and resource limits. Validated with `helm template`.

| Model | Without Skill | With Skill | Improvement |
|-------|--------------|------------|-------------|
| Sonnet 4.6 | 18/19 $0.68 | 18/19 **$0.57** | Same score, 16% cheaper. Skill agent found correct chart values faster. |
| Opus 4.6 | 16/19 $2.50 | **18/19** **$1.57** | +2 checks and 37% cheaper. Skill provided exact Valkey Helm chart repo, value keys, and Bitnami-specific config that the model couldn't guess. |

**Task: Production config audit and operational questions**

Fix a deliberately broken valkey.conf migrated from Redis 7.2 (15 problems), answer 5 operational questions about COMMANDLOG, ACL, dual-channel replication, I/O threads, and cluster databases.

| Model | Without Skill | With Skill | Improvement |
|-------|--------------|------------|-------------|
| Sonnet 4.6 | 16/22 | **17/22** | +1 check. Skill caught the COMMANDLOG config directive rename that the model missed. |

### valkey-dev (server internals skill)

**Task: Find and fix a cluster split-brain bug in Valkey source**

Agent receives Valkey source with an introduced bug (clusterShouldDeferEpochBump prevents epoch collision resolution after failover). Only symptoms provided - agent must find the root cause in ~200 source files and fix it.

| Model | Without Skill | With Skill | Improvement |
|-------|--------------|------------|-------------|
| Sonnet 4.5 | 8/12 | **11/12** | +3 checks. Skill guided the agent to the cluster epoch resolution code path faster. |

## Skills Tested But Removed (No Value)

| Skill | Why Removed |
|-------|-------------|
| valkey-module-dev | Rust `valkey-module` crate is well-documented in training data. 21/21 all conditions. |
| valkey-json-dev | C++ codebase navigable without domain skills. Skill actively hurt Opus (-6 tests). |
| valkey-modules | valkey-search query syntax is identical to RediSearch. 2/3 all conditions. |

## Methodology

- **5 tasks**, each run with skill and without skill conditions
- **Isolated `/tmp/` workspaces** with no `.git`, no repo CLAUDE.md
- **Web access blocked** via `--allowedTools` whitelist (no WebFetch/WebSearch/curl/wget)
- **60 turn limit** per agent
- **Deterministic test scripts** (grep, build, valkey-cli) - no AI judges
- **Bedrock API** (us-west-2)
- Skills loaded by copying skill directory into `.claude/skills/` in the workspace
