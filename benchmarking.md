# Benchmark Results

Isolated workspaces, no web access, 60-turn limit. Sonnet 4.6 and Opus 4.6 on Bedrock.

## Skill Wins

| Skill | Task | Model | Without | With | Delta |
|-------|------|-------|---------|------|-------|
| **valkey** | 10 Valkey 9.x problem-solving scenarios | Sonnet | 6/14 | **10/14** | +4 |
| **valkey** | Same | Opus | 5/14 | **10/14** | +5 |
| **valkey-dev** | Find and fix cluster split-brain bug in ~200 source files | Sonnet | 8/12 | **11/12** | +3 |
| **valkey-ops** | Helm chart for 6-node Valkey cluster on K8s | Opus | 16/19 $2.50 | **18/19** $1.57 | +2, 37% cheaper |
| **valkey-ops** | Production config audit (15 problems) + 5 ops questions | Sonnet | 16/22 | **17/22** | +1 |

Without skills, models default to Redis 7.x patterns. Skills teach Valkey-specific commands (COMMANDLOG, SET IFEQ, HSETEX, DELIFEQ, CLUSTERSCAN) and config (lazyfree defaults, io-threads changes, Helm chart values).

## Removed Skills

Three skills showed no measurable value and were deleted: valkey-module-dev (Rust crate already in training data), valkey-json-dev (C++ navigable without skills), valkey-modules (same query syntax as RediSearch).
