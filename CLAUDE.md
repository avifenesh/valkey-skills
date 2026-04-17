# valkey-skills

> Domain-specific AI skills for the Valkey ecosystem - application development, server internals, operations, GLIDE client (7 languages), and module contributor skills

## Skills

### Valkey Core (6 skills)

| Directory | Skill | Audience | Files |
|-----------|-------|----------|-------|
| `skills/valkey/` | valkey | Application developers - Valkey-specific features, patterns, best practices | 41 |
| `skills/valkey-dev/` | valkey-dev | Valkey server contributors | 65 |
| `skills/valkey-ops/` | valkey-ops | Self-hosted Valkey operators | 61 |
| `skills/glide-dev/` | glide-dev | GLIDE client library contributors - Rust core, language bindings, build system | 7 |
| `skills/valkey-search-dev/` | valkey-search-dev | valkey-search module contributors - C++ architecture, index types, query engine, build | 21 |
| `skills/valkey-bloom-dev/` | valkey-bloom-dev | valkey-bloom module contributors - Rust scalable bloom filters, build, replication | 13 |

### GLIDE Per-Language (7 skills)

| Directory | Skill | Content |
|-----------|-------|---------|
| `skills/valkey-glide-python/` | valkey-glide-python | Async/sync API, all data types, OTel, TLS, batching, PubSub, streams |
| `skills/valkey-glide-java/` | valkey-glide-java | CompletableFuture API, configuration builders, batching, streams, server modules |
| `skills/valkey-glide-nodejs/` | valkey-glide-nodejs | Promise API, TypeScript, ESM/CJS, batching, PubSub, streams |
| `skills/valkey-glide-go/` | valkey-glide-go | Synchronous API, CGO, Result[T], batching, error handling |
| `skills/valkey-glide-csharp/` | valkey-glide-csharp | Async/await API, .NET 8.0+ (preview), configuration builders |
| `skills/valkey-glide-php/` | valkey-glide-php | C extension (PHP 8.1+), PIE/Composer/PECL |
| `skills/valkey-glide-ruby/` | valkey-glide-ruby | valkey-rb gem (GA), redis-rb drop-in replacement |

### Migration Skills (6 standalone + 1 framework)

| Directory | Skill | Content | Files |
|-----------|-------|---------|-------|
| `skills/migrate-jedis/` | migrate-jedis | Jedis to GLIDE Java migration | 3 |
| `skills/migrate-lettuce/` | migrate-lettuce | Lettuce to GLIDE Java migration | 3 |
| `skills/migrate-ioredis/` | migrate-ioredis | ioredis to GLIDE Node.js migration | 3 |
| `skills/migrate-redis-py/` | migrate-redis-py | redis-py to GLIDE Python migration | 3 |
| `skills/migrate-go-redis/` | migrate-go-redis | go-redis to GLIDE Go migration | 3 |
| `skills/migrate-stackexchange/` | migrate-stackexchange | StackExchange.Redis to GLIDE C# migration | 3 |
| `skills/spring-data-valkey/` | spring-data-valkey | Spring Boot + Spring Data Valkey integration | 3 |

### Glide-MQ (3 skills, vendored from upstream)

`skills/glide-mq/`, `skills/glide-mq-migrate-bullmq/`, `skills/glide-mq-migrate-bee/`. SKILL.md + `references/*` vendored from [avifenesh/glide-mq](https://github.com/avifenesh/glide-mq) by `scripts/sync-glide-mq-upstream.sh`; pin in `UPSTREAM-GLIDE-MQ.md`. `.github/workflows/sync-glide-mq.yml` runs weekly and opens a PR on drift; `version-watch.yml` tracks version bumps separately.

## Architecture

Each skill is a self-contained installable plugin under `skills/<name>/`:
- `.claude-plugin/plugin.json` - plugin metadata (name, version, description)
- `skills/<name>/SKILL.md` - concise router (<250 lines) with trigger phrases and reference tables
- `skills/<name>/reference/` - deep RAG library of focused docs (each under 300 lines)

Per-language GLIDE skills (Python, Java, Node.js, Go have 9 files; C#, PHP, Ruby have 4 files) are fully language-specific - each contains its own complete API reference, patterns, and examples with no shared reference files. Migration skills each have 2 reference files (api-mapping and advanced-patterns).

The AI loads SKILL.md into context, scans the tables, and reads only the specific reference file needed. No context bloat.

## Installation

Users add the marketplace once, then install individual skills:
```
/plugin marketplace add avifenesh/valkey-skills
/plugin install valkey@valkey-skills
/plugin install valkey-glide-python@valkey-skills
```

The repo also installs as an all-in-one plugin for users who want everything.

## Dev Commands

Skills-only plugin - no build step, no runtime code. `npm test` exits with a message.

## Editing Skills

- New reference docs go in the relevant `skills/{skill}/skills/{skill}/reference/` subdirectory
- Reference directories are flat - place new files directly in reference/ with a descriptive prefix matching the SKILL.md table grouping (e.g., patterns-caching-strategies.md, architecture-overview.md)
- Keep reference files focused on one topic, under 300 lines when possible
- Start each reference doc with a "Use when" trigger line
- Update the SKILL.md router table to include the new file

## Version Baseline

Skills were written and verified against these versions. Update when new releases ship.

| Component | Version | Skills Affected |
|-----------|---------|----------------|
| Valkey server | 9.0.3 | valkey, valkey-dev, valkey-ops |
| Valkey GLIDE | 2.3.1 | valkey-glide, all per-language skills |
| valkey-search | 1.2.0 | valkey-search-dev |
| valkey-json | GA | (reference only) |
| valkey-bloom | GA | valkey-bloom-dev |
| Valkey GLIDE (source) | 2.3.1 | glide-dev |
| Spring Data Valkey | 1.0 | spring-data-valkey |

Last full review: 2026-04-11

## Critical Rules

1. **Plain text output** - No emojis, no ASCII art.
2. **Source-verified** - Reference docs must be verified against actual source code, not just web research.
3. **No unnecessary files** - Don't create summary files, plan files, audit files, or temp docs.
4. **Use single dash for em-dashes** - In prose, use ` - ` (single dash with spaces), never ` -- `.
