# valkey-skills

AI skills for the [Valkey](https://valkey.io) ecosystem. Teaches coding assistants what they don't know from training data - Valkey 9.x commands, GLIDE client APIs, operational defaults, and server internals.

24 skills, 190 markdown files (SKILL.md routers + reference docs), source-verified against actual Valkey/GLIDE source code. Works with Claude Code, Cursor, Codex, Copilot, Gemini CLI, OpenCode, Kiro, and any tool supporting the [Agent Skills standard](https://agentskills.io).

## Why

AI models are trained on snapshots of the internet. Valkey-specific features - `COMMANDLOG`, `SET IFEQ`, `HSETEX`/`HGETEX`, `DELIFEQ`, `CLUSTERSCAN` - don't exist in training data. Without skills, models default to Redis 7.x answers.

GLIDE has different method signatures, argument orders, and async patterns than every Redis client it replaces. Migration code generated from Redis knowledge doesn't compile.

Skills fix this. Benchmarked, measured, proven.

## Benchmarks

Tested on Sonnet 4.6 and Opus 4.6 (Bedrock). Isolated workspaces, no web access, no shared context. Each condition ran multiple times. Skills that showed no value were removed.

| Skill | Task | Model | Without | With | Delta |
|-------|------|-------|---------|------|-------|
| **valkey** | 10 Valkey 9.x problem-solving scenarios | Sonnet | 6/14 | **10/14** | **+4** |
| **valkey** | Same | Opus | 5/14 | **10/14** | **+5** |
| **valkey-dev** | Find and fix cluster split-brain bug in ~200 C files | Sonnet | 8/12 | **11/12** | **+3** |
| **valkey-ops** | Helm chart for 6-node Valkey cluster on K8s | Opus | 16/19 ($2.50) | **18/19** ($1.57) | **+2**, 37% cheaper |
| **valkey-ops** | Config audit migrated from Redis 7.2 | Sonnet | 16/22 | **17/22** | **+1** |

Three skills were cut after benchmarking: `valkey-module-dev` (Rust crate already in training data), `valkey-json-dev` (C++ navigable without skills), and a query syntax skill (identical to RediSearch). We don't pad the count.

Full results in [benchmarking.md](benchmarking.md).

## Install

### Claude Code

```
/plugin marketplace add avifenesh/valkey-skills
/plugin install valkey-skills@valkey-skills
```

### Agent Skills CLI (cross-tool)

```bash
npx skills add avifenesh/valkey-skills
```

Works with Cursor, Copilot, Gemini CLI, OpenCode, Kiro, and any tool supporting the Agent Skills standard.

### Codex CLI

```bash
git clone https://github.com/avifenesh/valkey-skills.git
codex --plugin-dir ./valkey-skills
```

### Manual

Clone and copy to your tool's skills directory:

| Tool | Copy to |
|------|---------|
| Claude Code | `~/.claude/skills/` or `--plugin-dir ./valkey-skills` |
| Codex CLI | `~/.codex/skills/` |
| Cursor | `.cursor/skills/` |
| OpenCode | `~/.config/opencode/skills/` |
| Kiro | `.kiro/skills/` |

## Skills

### Application Development

| Skill | Audience | Files |
|-------|----------|-------|
| **valkey** | App developers - Valkey 9.x features, patterns, best practices | 36 |

### GLIDE Per-Language

| Skill | Language | Files |
|-------|----------|-------|
| **valkey-glide** | Router - directs to the right language skill | 1 |
| **valkey-glide-python** | Python (async + sync) | 9 |
| **valkey-glide-java** | Java (CompletableFuture) | 9 |
| **valkey-glide-nodejs** | Node.js / TypeScript | 9 |
| **valkey-glide-go** | Go (synchronous, CGO) | 9 |
| **valkey-glide-csharp** | C# (.NET 8.0+) | 4 |
| **valkey-glide-php** | PHP 8.2/8.3 | 4 |
| **valkey-glide-ruby** | Ruby | 4 |

### Migration

| Skill | From | To |
|-------|------|----|
| **migrate-redis-py** | redis-py | GLIDE Python |
| **migrate-jedis** | Jedis | GLIDE Java |
| **migrate-lettuce** | Lettuce | GLIDE Java |
| **migrate-ioredis** | ioredis | GLIDE Node.js |
| **migrate-go-redis** | go-redis | GLIDE Go |
| **migrate-stackexchange** | StackExchange.Redis | GLIDE C# |
| **spring-data-valkey** | Spring Data Redis | Spring Data Valkey |

### Operations

| Skill | Audience | Files |
|-------|----------|-------|
| **valkey-ops** | Self-hosted operators - K8s, Helm, monitoring, security, config migration | 14 |

### Server and Module Development

| Skill | Audience | Files |
|-------|----------|-------|
| **valkey-dev** | Server contributors - C internals, data structures, threading, cluster, replication | 12 |
| **valkey-search-dev** | valkey-search contributors - C++, vector/text indexes, query engine | 21 |
| **valkey-bloom-dev** | valkey-bloom contributors - Rust, scalable bloom filters | 13 |
| **glide-dev** | GLIDE core contributors - Rust core, FFI bindings, build system | 7 |

### Message Queues

| Skill | Purpose | Files |
|-------|---------|-------|
| **glide-mq** | Queues, workers, schedulers, workflows on Valkey | 11 |
| **glide-mq-migrate-bullmq** | BullMQ to glide-mq migration | 3 |
| **glide-mq-migrate-bee** | Bee-Queue to glide-mq migration | 3 |

## How It Works

Each skill follows a router pattern. The AI loads only the frontmatter (name, description, trigger phrases) into context at startup. When it encounters a relevant question, it loads the full SKILL.md router, scans the routing table, and reads only the specific reference file it needs.

```
skills/valkey/
  SKILL.md                          # Frontmatter loaded at startup, full content on demand
  reference/
    valkey-features-hash-field-ttl.md
    patterns-caching-strategies.md   # Loaded only when relevant
    advanced-latency-diagnosis.md
    ...
```

Thousands of lines of reference material indexed across skills. Only the SKILL.md router and the specific reference file needed get loaded.

## Quality

Every reference file verified against actual source code.

- **valkey**: Valkey 9.0.3 source
- **valkey-dev**: `src/server.c`, `src/cluster.c`, `src/replication.c`, etc.
- **valkey-ops**: Helm charts, official config templates
- **GLIDE skills**: Rust FFI core and per-language bindings (GLIDE 2.3.1)
- **valkey-search-dev**: 37,050 lines across 143 C++ files (v1.2.0)
- **valkey-bloom-dev**: Rust source (GA)

Passes [agnix](https://github.com/agent-sh/agnix) linter - 0 errors, 0 warnings.

## Version Baseline

| Component | Version |
|-----------|---------|
| Valkey server | 9.0.3 |
| Valkey GLIDE | 2.3.1 |
| valkey-search | 1.2.0 |
| valkey-bloom | GA |
| Spring Data Valkey | 1.0 |

## Contributing

Found an error or gap? Open an issue with the file path, what's wrong, and a source link. PRs welcome - follow the router pattern (SKILL.md + reference/ files under 300 lines).

## License

BSD-3-Clause
