# valkey-skills

AI skills for the [Valkey](https://valkey.io) ecosystem. 15 skills across 281 files of source-verified reference material.

Gives AI coding assistants deep knowledge of Valkey commands, server internals, operations, [GLIDE](https://github.com/valkey-io/valkey-glide) client across 7 languages, module development, and message queues. Works with Claude Code, Cursor, Codex, Copilot, Gemini CLI, OpenCode, Kiro, and any tool supporting the [Agent Skills standard](https://agentskills.io).

## Use this when

- Building applications with Valkey (caching, queues, sessions, rate limiting, pub/sub, leaderboards)
- Contributing to the Valkey server C codebase
- Deploying and operating self-hosted Valkey (Sentinel, cluster, Kubernetes, Helm)
- Using the GLIDE client in Python, Java, Node.js, Go, C#, PHP, or Ruby
- Migrating from Redis clients (redis-py, Jedis, Lettuce, ioredis, go-redis, StackExchange.Redis)
- Contributing to valkey-search, valkey-bloom modules
- Building message queues with glide-mq

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

## Measured impact

Benchmarked on Sonnet 4.6 and Opus 4.6 (Bedrock). Isolated workspaces, no web access, 60-turn limit per agent.

| Skill | Task | Without | With | Result |
|-------|------|---------|------|--------|
| **valkey** | 10 Valkey 9.x problem-solving scenarios | Sonnet 6/14, Opus 5/14 | Sonnet 10/14, Opus 10/14 | **+4 to +5 checks**. Skill taught COMMANDLOG, SET IFEQ, HSETEX/HGETEX, DELIFEQ, CLUSTERSCAN. Without it, models fell back to Redis 7.x answers. |
| **valkey-ops** | Helm chart for Valkey K8s cluster | Opus 16/19, $2.50 | Opus 18/19, $1.57 | **+2 checks, 37% cheaper**. Exact chart values the model couldn't guess. |
| **valkey-ops** | Production config audit | Sonnet 16/22 | Sonnet 17/22 | **+1 check**. Caught COMMANDLOG config rename. |

Skills that showed no measurable value were removed from the repo.

## Skills

### Application Development

| Skill | Audience | Files |
|-------|----------|-------|
| **valkey** | App developers - Valkey-specific features, patterns, best practices | 41 |

### Server and Module Development

| Skill | Audience | Files |
|-------|----------|-------|
| **valkey-dev** | Server contributors - C internals, data structures, threading, cluster, replication | 65 |
| **valkey-bloom-dev** | valkey-bloom contributors - Rust, scalable bloom filters, replication | 13 |
| **valkey-search-dev** | valkey-search contributors - C++, vector/text indexes, query engine, gRPC coordinator | 21 |
| **glide-dev** | GLIDE client contributors - Rust core, FFI bindings, build system | 7 |

### Operations

| Skill | Audience | Files |
|-------|----------|-------|
| **valkey-ops** | Self-hosted operators - deployment, monitoring, security, Kubernetes, Helm, troubleshooting | 61 |

### GLIDE Per-Language

| Skill | Language | Migrating From |
|-------|----------|----------------|
| **valkey-glide-python** | Python (async + sync) | redis-py |
| **valkey-glide-java** | Java | Jedis, Lettuce |
| **valkey-glide-nodejs** | Node.js / TypeScript | ioredis |
| **valkey-glide-go** | Go | go-redis |
| **valkey-glide-csharp** | C# (.NET 8.0+) | StackExchange.Redis |
| **valkey-glide-php** | PHP 8.1+ | phpredis |
| **valkey-glide-ruby** | Ruby | redis-rb |

### Migration

| Skill | From | To |
|-------|------|----|
| **migrate-jedis** | Jedis | GLIDE Java |
| **migrate-lettuce** | Lettuce | GLIDE Java |
| **migrate-ioredis** | ioredis | GLIDE Node.js |
| **migrate-redis-py** | redis-py | GLIDE Python |
| **migrate-go-redis** | go-redis | GLIDE Go |
| **migrate-stackexchange** | StackExchange.Redis | GLIDE C# |
| **spring-data-valkey** | Spring Data Redis | Spring Data Valkey |

### Message Queues

| Skill | Purpose |
|-------|---------|
| **glide-mq** | Queues, workers, schedulers, workflows on Valkey |
| **glide-mq-migrate-bullmq** | Migrate from BullMQ |
| **glide-mq-migrate-bee** | Migrate from Bee-Queue |

## How it works

Each skill follows a router pattern:

```
skills/valkey/
  SKILL.md                          # Router (<250 lines) - loaded into AI context
  reference/
    patterns-caching-strategies.md   # Loaded on demand when relevant
    valkey-features-hash-field-ttl.md
    advanced-latency-diagnosis.md
    ...focused reference files
```

1. AI reads the SKILL.md router (routing table maps queries to reference files)
2. AI identifies which reference file answers the question
3. AI loads only that file (100-300 lines each)

No context bloat. 67K lines available, only ~250 loaded per question.

## Quality

Every reference file is verified against actual source code, not web research.

- **valkey**: verified against Valkey 9.0.3 source, GLIDE 2.3.0, valkey-search 1.2.0
- **valkey-dev**: verified against `src/server.c`, `src/cluster.c`, `src/replication.c`
- **valkey-bloom-dev**: verified against Rust source
- **valkey-search-dev**: verified against 37,050 lines across 143 C++ files
- **GLIDE skills**: verified against Rust FFI core and per-language bindings

Passes [agnix](https://github.com/agent-sh/agnix) linter with 0 errors, 0 warnings.

## Version baseline

| Component | Version |
|-----------|---------|
| Valkey server | 9.0.3 |
| Valkey GLIDE | 2.3.0 |
| valkey-search | 1.2.0 |
| valkey-json | GA |
| valkey-bloom | GA |
| glide-mq | 0.14.0 |
| Spring Data Valkey | 1.0 |

## Contributing

Found an error or gap?

1. Open an issue with the file path and what's wrong
2. Include a source link (Valkey repo, GLIDE repo, or module repo)
3. PRs welcome - follow the router pattern (SKILL.md + flat reference/ files under 300 lines)

## Related

- [Valkey](https://github.com/valkey-io/valkey) - The Valkey server
- [Valkey GLIDE](https://github.com/valkey-io/valkey-glide) - Official multi-language client
- [glide-mq](https://github.com/avifenesh/glide-mq) - Message queue library for Valkey
- [agent-sh](https://github.com/agent-sh) - AI plugin ecosystem
- [Agent Skills standard](https://agentskills.io) - Cross-tool skill specification

## License

BSD-3-Clause
