# valkey-skills

> Domain-specific AI skills for the Valkey ecosystem - application development, server internals, operations, GLIDE client (7 languages), ecosystem tools, and message queues

## Skills

### Valkey Core (5 skills, 204 reference files)

| Directory | Skill | Audience | Files |
|-----------|-------|----------|-------|
| `skills/valkey/` | valkey | Application developers using Valkey | 39 |
| `skills/valkey-dev/` | valkey-dev | Valkey server contributors | 59 |
| `skills/valkey-ops/` | valkey-ops | Self-hosted Valkey operators | 52 |
| `skills/valkey-glide/` | valkey-glide | GLIDE shared architecture, features, best practices | 26 |
| `skills/valkey-ecosystem/` | valkey-ecosystem | Ecosystem tools and services | 28 |

### GLIDE Per-Language (7 sub-skills under valkey-glide/)

| Directory | Skill | Content |
|-----------|-------|---------|
| `skills/valkey-glide/python/` | valkey-glide-python | Async (valkey-glide) / sync (valkey-glide-sync), all data types, OTel, redis-py migration |
| `skills/valkey-glide/java/` | valkey-glide-java | CompletableFuture, Spring Data Valkey, Jedis/Lettuce migration |
| `skills/valkey-glide/nodejs/` | valkey-glide-nodejs | TypeScript, ESM/CJS, ioredis migration |
| `skills/valkey-glide/go/` | valkey-glide-go | CGO, Result[T], go-redis migration |
| `skills/valkey-glide/csharp/` | valkey-glide-csharp | .NET 6.0+/8.0+ (preview), StackExchange.Redis migration |
| `skills/valkey-glide/php/` | valkey-glide-php | C extension (PHP 8.1+), PIE/Composer/PECL |
| `skills/valkey-glide/ruby/` | valkey-glide-ruby | valkey-rb gem (GA), redis-rb drop-in replacement |

### Glide-MQ (3 skills under glide-mq/)

| Directory | Skill | Purpose |
|-----------|-------|---------|
| `skills/glide-mq/` | glide-mq | Greenfield queue development - queues, workers, producers, scheduling, workflows |
| `skills/glide-mq/migrate-bullmq/` | glide-mq-migrate-bullmq | Migrate from BullMQ - connection, API mapping, breaking changes |
| `skills/glide-mq/migrate-bee/` | glide-mq-migrate-bee | Migrate from Bee-Queue - chained builder to options, API mapping |

## Architecture

Core skills (valkey, valkey-dev, valkey-ops, valkey-glide, valkey-ecosystem) follow the router pattern:
- `SKILL.md` - concise router (<500 lines) with trigger phrases and reference tables
- `reference/` - deep RAG library of focused docs (most under 300 lines)

Per-language GLIDE skills and Glide-MQ skills are self-contained single-file SKILL.md documents.

The AI loads SKILL.md into context, scans the tables, and reads only the specific reference file needed. No context bloat.

## Dev Commands

Skills-only plugin - no build step, no runtime code. `npm test` exits with a message.

Skills are auto-discovered from the `skills/` directory tree - no registration in plugin.json needed.

## Editing Skills

- New reference docs go in the relevant `skills/{skill}/reference/` subdirectory
- Follow existing subdirectory grouping (e.g., `commands/`, `patterns/`, `architecture/`)
- Keep reference files focused on one topic, under 300 lines when possible
- Start each reference doc with a "Use when" trigger line
- Update the SKILL.md router table to include the new file

## Version Baseline

Skills were written and verified against these versions. Update when new releases ship.

| Component | Version | Skills Affected |
|-----------|---------|----------------|
| Valkey server | 9.0.3 | valkey, valkey-dev, valkey-ops |
| Valkey GLIDE | 2.3.0 | valkey-glide, all per-language skills |
| valkey-search | 1.2.0 | valkey-ecosystem (modules/search) |
| valkey-json | GA | valkey-ecosystem (modules/json) |
| valkey-bloom | GA | valkey-ecosystem (modules/bloom) |
| glide-mq | 0.14.0 | glide-mq, migrate-bullmq, migrate-bee |
| Spring Data Valkey | 1.0 | valkey-glide-java (Spring section) |

Last full review: 2026-03-30

## Critical Rules

1. **Plain text output** - No emojis, no ASCII art.
2. **Source-verified** - Reference docs must be verified against actual source code, not just web research.
3. **No unnecessary files** - Don't create summary files, plan files, audit files, or temp docs.
4. **Use single dash for em-dashes** - In prose, use ` - ` (single dash with spaces), never ` -- `.
