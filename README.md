# valkey-skills

AI skills for the [Valkey](https://valkey.io) ecosystem - 27 skills, 343 files, 67K lines of source-verified reference material.

Gives AI coding assistants (Claude Code, Cursor, Codex, Copilot, Gemini CLI, OpenCode, Kiro) deep knowledge of Valkey commands, server internals, operations, [GLIDE](https://github.com/valkey-io/valkey-glide) client across 7 languages, module development, and message queues.

## Use this when

- Building applications with Valkey (caching, queues, sessions, rate limiting, pub/sub, leaderboards)
- Contributing to the Valkey server C codebase
- Deploying and operating self-hosted Valkey (Sentinel, cluster, Kubernetes)
- Using the GLIDE client in Python, Java, Node.js, Go, C#, PHP, or Ruby
- Migrating from Redis clients (redis-py, Jedis, Lettuce, ioredis, go-redis, StackExchange.Redis)
- Building custom Valkey modules in C or Rust
- Contributing to valkey-search, valkey-json, or valkey-bloom modules
- Building message queues with glide-mq

## Install

### Claude Code

```
/plugin marketplace add avifenesh/valkey-skills
/plugin install valkey-skills@valkey-skills
```

### Codex CLI

```bash
git clone https://github.com/avifenesh/valkey-skills.git
cp -r valkey-skills/skills/* ~/.codex/skills/
```

### Agent Skills CLI (cross-tool)

```bash
npx skills add avifenesh/valkey-skills
```

Installs into `.agents/skills/` in your project. Works with Cursor, Copilot, Gemini CLI, OpenCode, Kiro, and any tool supporting the [Agent Skills standard](https://agentskills.io).

### Manual (any tool)

Clone and copy to your tool's skills directory:

```bash
git clone https://github.com/avifenesh/valkey-skills.git
```

| Tool | Copy to |
|------|---------|
| Claude Code | `~/.claude/skills/` or use `--plugin-dir ./valkey-skills` |
| Codex CLI | `~/.codex/skills/` |
| Cursor | `.cursor/skills/` |
| OpenCode | `~/.config/opencode/skills/` |
| Kiro | `.kiro/skills/` |
| Any Agent Skills tool | `.agents/skills/` |

## Skills

### Application Development

| Skill | Audience | Files |
|-------|----------|-------|
| **valkey** | App developers - commands, data types, patterns, best practices | 36 |
| **valkey-modules** | Module users - valkey-search, valkey-json, valkey-bloom | 6 |

### Server and Module Development

| Skill | Audience | Files |
|-------|----------|-------|
| **valkey-dev** | Server contributors - C internals, data structures, threading, cluster, replication | 65 |
| **valkey-module-dev** | Custom module developers - ValkeyModule_* C API (376 functions, 42 categories) | 46 |
| **valkey-bloom-dev** | valkey-bloom contributors - Rust, scalable bloom filters, replication | 13 |
| **valkey-json-dev** | valkey-json contributors - C++, RapidJSON, JSONPath engine, KeyTable | 15 |
| **valkey-search-dev** | valkey-search contributors - C++, vector/text indexes, query engine, gRPC coordinator | 21 |
| **glide-dev** | GLIDE client contributors - Rust core, FFI bindings, build system | 7 |

### Operations

| Skill | Audience | Files |
|-------|----------|-------|
| **valkey-ops** | Self-hosted operators - deployment, monitoring, security, Kubernetes, troubleshooting | 61 |

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
    patterns-queues-streams.md
    best-practices-memory.md
    ...35 focused reference files
```

1. AI reads the SKILL.md router (routing table maps queries to files)
2. AI identifies which reference file answers the question
3. AI loads only that file (100-300 lines each)
4. No context bloat - 67K lines available, only ~250 loaded per question

## Quality

Every reference file is source-verified against actual code:

- **valkey-dev**: verified against `src/server.c`, `src/module.c`, `src/cluster.c` (Valkey 9.0.3)
- **valkey-module-dev**: verified against all 376 `REGISTER_API()` calls in `module.c` (14,857 lines)
- **valkey-bloom-dev**: verified against the Rust source (`src/bloom/utils.rs`, `command_handler.rs`)
- **valkey-json-dev**: verified against the C++ source (`src/json/dom.cc`, `selector.cc`, `keytable.cc`)
- **valkey-search-dev**: verified against the C++ source (37,050 lines across 143 files)
- **GLIDE skills**: verified against the Rust FFI core and per-language bindings

Built with a 13-step pipeline: write, gap analysis, gap fill, deep research, enrichment, enhance, merge, unification, adversarial validation, fix, router write, router enhance, commit. Optimized per RAG research for AI consumption (flat reference dirs, descriptions under 250 chars, no filler language, every file under 300 lines).

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
