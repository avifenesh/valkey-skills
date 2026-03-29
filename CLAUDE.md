# valkey-skills

> Domain-specific AI skills for the Valkey ecosystem - 15 skills covering application development, server internals, operations, GLIDE client (7 languages), ecosystem tools, and message queues

## Skills

### Valkey Core (5 skills, 208 reference files)

| Directory | Skill | Audience | Files |
|-----------|-------|----------|-------|
| `valkey/` | valkey | Application developers using Valkey | 37 |
| `valkey-dev/` | valkey-dev | Valkey server contributors | 59 |
| `valkey-ops/` | valkey-ops | Self-hosted Valkey operators | 52 |
| `valkey-glide/` | valkey-glide | GLIDE shared architecture, features, best practices | 32 |
| `valkey-ecosystem/` | valkey-ecosystem | Ecosystem tools and services | 28 |

### GLIDE Per-Language (7 skills, code-heavy)

| Directory | Skill | Lines | Content |
|-----------|-------|-------|---------|
| `valkey-glide-python/` | valkey-glide-python | 838 | Async/sync, all data types, OTel, redis-py migration |
| `valkey-glide-java/` | valkey-glide-java | 772 | CompletableFuture, Spring, Jedis/Lettuce migration |
| `valkey-glide-nodejs/` | valkey-glide-nodejs | 765 | TypeScript, ESM/CJS, ioredis migration |
| `valkey-glide-go/` | valkey-glide-go | 581 | CGO, Result[T], go-redis migration |
| `valkey-glide-csharp/` | valkey-glide-csharp | 396 | .NET 8.0+, StackExchange.Redis migration |
| `valkey-glide-php/` | valkey-glide-php | 262 | C extension, PIE/Composer/PECL |
| `valkey-glide-ruby/` | valkey-glide-ruby | 287 | redis-rb API, v1.0.0, full command surface |

### Glide-MQ (Valkey-Powered Message Queues, 3 skills)

| Directory | Skill | Purpose |
|-----------|-------|---------|
| `glide-mq/` | glide-mq | Greenfield queue development - queues, workers, producers, scheduling, workflows |
| `glide-mq-migrate-bullmq/` | glide-mq-migrate-bullmq | Migrate from BullMQ - connection, API mapping, breaking changes |
| `glide-mq-migrate-bee/` | glide-mq-migrate-bee | Migrate from Bee-Queue - chained builder to options, API mapping |

## Architecture

Core skills (valkey, valkey-dev, valkey-ops, valkey-glide, valkey-ecosystem) follow the router pattern:
- `SKILL.md` - concise router (<500 lines) with trigger phrases and reference tables
- `reference/` - deep RAG library of focused docs (100-300 lines each)

Per-language GLIDE skills and Glide-MQ skills are self-contained single-file SKILL.md documents.

The AI loads SKILL.md into context, scans the tables, and reads only the specific reference file needed. No context bloat.

## Quality

208 reference files across 5 Valkey core skills + 7 per-language GLIDE skills + 3 Glide-MQ skills. Every skill built with the full 13-phase pipeline: wave 1 writers, gap analysis, wave 2 fill, deep research, enrichment, enhance (5 groups), merge-sort (2 pairs), unification, validate (3 per subject), fix, SKILL.md write, SKILL.md enhance, commit.

valkey-dev is the reference implementation:
- 59 reference files
- Every claim verified against actual Valkey C source code
- 1,440 claims validated by 15 independent review agents
- 29 errors found and fixed (2% initial error rate -> 0%)

## Critical Rules

1. **Plain text output** - No emojis, no ASCII art.
2. **Source-verified** - Reference docs must be verified against actual source code, not just web research.
3. **No unnecessary files** - Don't create summary files, plan files, audit files, or temp docs.
4. **Use single dash for em-dashes** - In prose, use ` - ` (single dash with spaces), never ` -- `.
