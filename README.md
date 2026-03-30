# valkey-skills

Domain-specific AI skills for the [Valkey](https://valkey.io) ecosystem. Give your AI coding assistant deep knowledge of Valkey commands, architecture, operations, and the official GLIDE client across 7 languages.

## What This Is

A collection of 15 AI skills that teach Claude Code, Cursor, Codex, and other AI assistants how to work with Valkey. Instead of relying on potentially outdated training data, these skills provide source-verified, up-to-date reference material that the AI loads on demand.

Each skill is a focused knowledge package:
- A **SKILL.md** router that the AI reads to understand what's available
- **reference/** docs (100-300 lines each) that get loaded only when relevant
- No context bloat - the AI reads only what it needs per question

## Install

### Claude Code (marketplace)

```
/plugin marketplace add avifenesh/valkey-skills
/plugin install valkey@valkey-skills
/plugin install valkey-glide@valkey-skills
```

### npm (all platforms)

```bash
npm install -g valkey-skills
```

### Manual

```bash
git clone https://github.com/avifenesh/valkey-skills.git
```

## Skills Overview

### Core Skills

| Skill | Who It's For | What It Covers |
|-------|-------------|----------------|
| **valkey** | App developers | Commands, data types, patterns (caching, queues, rate limiting, pub/sub), best practices |
| **valkey-dev** | Server contributors | C source internals, data structures, threading, memory, replication, cluster protocol |
| **valkey-ops** | Operators | Deployment, monitoring, security, persistence, upgrades, troubleshooting |
| **valkey-glide** | GLIDE users (all languages) | Shared architecture, connection model, features, migration guides |
| **valkey-ecosystem** | Evaluators & integrators | Modules (JSON, Bloom, Search), managed services, monitoring tools, Docker, K8s |

### GLIDE Per-Language

For language-specific API reference, code examples, and migration from your current Redis client:

| Skill | Language | Migrating From |
|-------|----------|---------------|
| **valkey-glide-python** | Python (async + sync) | redis-py |
| **valkey-glide-java** | Java | Jedis, Lettuce |
| **valkey-glide-nodejs** | Node.js / TypeScript | ioredis |
| **valkey-glide-go** | Go | go-redis |
| **valkey-glide-csharp** | C# (.NET 6.0+) | StackExchange.Redis |
| **valkey-glide-php** | PHP 8.1+ | phpredis, Predis |
| **valkey-glide-ruby** | Ruby | redis-rb |

### Glide-MQ (Message Queues)

| Skill | Purpose |
|-------|---------|
| **glide-mq** | Build queues, workers, schedulers, and workflows on Valkey |
| **glide-mq-migrate-bullmq** | Migrate from BullMQ |
| **glide-mq-migrate-bee** | Migrate from Bee-Queue |

## How It Works

When you ask your AI assistant a Valkey question, it:

1. Reads the relevant **SKILL.md** (the router)
2. Matches your question to a reference topic
3. Loads only that specific reference file into context
4. Answers with verified, current information

Example: asking "how do I set up a reliable task queue?" triggers the **valkey** skill, which routes to `reference/patterns/queues.md` - a focused doc covering list-based queues, stream-based consumer groups, and priority queues with code examples.

## What's Inside

```
valkey-skills/
  .claude-plugin/            # Plugin manifest
  skills/
    valkey/                  # 37 reference docs - commands, patterns, best practices
    valkey-dev/              # 59 reference docs - server internals (C source verified)
    valkey-ops/              # 52 reference docs - operations, monitoring, security
    valkey-glide/            # 32 reference docs - shared GLIDE architecture
      python/                #   Python API reference (async + sync)
      java/                  #   Java API reference (Spring, CompletableFuture)
      nodejs/                #   Node.js/TypeScript API reference
      go/                    #   Go API reference
      csharp/                #   C# API reference (.NET 6.0+)
      php/                   #   PHP API reference (8.1+)
      ruby/                  #   Ruby API reference (valkey-rb)
    valkey-ecosystem/        # 28 reference docs - modules, services, tools
    glide-mq/                # Queue development guide
      migrate-bullmq/        #   BullMQ migration
      migrate-bee/           #   Bee-Queue migration
```

208 reference files across the 5 core skills. Every claim verified against actual source code - Valkey C source, GLIDE Rust core, and official documentation.

## Quality

Built with a 13-phase pipeline including multi-agent review:

- Source-verified against actual code (not just web docs)
- 5-critic Opus review per skill with fix-validation passes
- Per-language GLIDE skills validated against the Rust FFI source
- 28 audit findings caught and fixed post-launch

## Contributing

Found an error or want to add coverage for a new Valkey feature?

1. Open an issue describing what's wrong or missing
2. Reference the specific file and line number
3. Include a source link (Valkey source, official docs, or GLIDE repo)

## Related

- [Valkey](https://github.com/valkey-io/valkey) - The Valkey server
- [Valkey GLIDE](https://github.com/valkey-io/valkey-glide) - Official multi-language client
- [glide-mq](https://github.com/avifenesh/glide-mq) - Message queue library for Valkey
- [agent-sh](https://github.com/agent-sh) - The AI plugin ecosystem these skills are part of

## License

BSD-3-Clause
