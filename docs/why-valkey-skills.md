# AI Skills for Valkey - Why and What

## AI Skills: What They Are

AI skills are structured reference files that get loaded into an AI coding assistant's context when a developer asks a relevant question. Instead of relying on the AI's training data (which may be outdated or wrong), skills provide verified, current information that the AI reads and uses to generate its response.

Think of it as documentation written for AI consumption rather than human browsing.

**How traditional docs work**: Developer searches valkey.io, reads a page, writes code based on what they read.

**How AI skills work**: Developer asks their AI assistant a question. The assistant loads the relevant skill file (100-300 lines, one topic), reads it, and generates a correct answer with working code.

The developer never sees the skill file. They just get better answers.

### The format

A skill is a markdown file with:
- A **trigger line** ("Use when building applications with Valkey") that tells the AI when to load it
- **Focused content** - one topic per file, typically 100-300 lines
- **Cross-references** to related skills for follow-up questions

Skills are installed once and work automatically across AI tools.

### Who is doing this

The Agent Skills format is an emerging standard adopted by Redis, Vercel (Next.js/React), TanStack, OpenAI, ElectricSQL, and others. Libraries ship skills inside their packages so AI assistants can correctly use their APIs.

- **Redis** published `redis/agent-skills` in January 2026 (40 GitHub stars, 29 rules covering best practices)
- **Vercel** published `vercel-labs/agent-skills` for Next.js and React
- **TanStack** ships skills via their Intent CLI for TanStack Router, Query, etc.
- The `npx skills add` CLI (1.4.6) discovers and installs skills across Claude Code, Cursor, Codex, Copilot, OpenCode, Cline, Kiro, Junie, and Amp

This is not a niche experiment. It is how library maintainers are addressing the fact that AI assistants generate incorrect code when they rely on training data alone.

## Why Valkey Needs This

### The training data problem

AI models are trained on internet-scale text data. For Redis, that means 15+ years of:
- Official documentation (2,000+ pages)
- Stack Overflow answers (300,000+ Redis-tagged questions)
- Blog posts, tutorials, courses, books
- Source code examples across millions of repositories

For Valkey, the training data is thin:
- valkey.io documentation (520 pages, started 2024)
- Stack Overflow (sparse - most questions still use the "redis" tag)
- Limited blog/tutorial coverage compared to Redis

The result: when a developer asks an AI assistant to help with Valkey, the assistant falls back to Redis knowledge. This creates real problems:

| What the developer asks | What the AI does without Valkey skills |
|------------------------|---------------------------------------|
| "Set up caching with Valkey" | Generates redis-py code, not GLIDE |
| "What modules does Valkey support?" | Describes Redis Stack, not valkey-search/valkey-json/valkey-bloom |
| "Use SET IFEQ for conditional update" | Doesn't know the command exists (Valkey-only, not in Redis) |
| "Upgrade from Redis to Valkey 9.0" | Generic advice, misses +failover ACL change, hash field expiration bugs, atomic slot migration |
| "How does Valkey's eviction work?" | Describes Redis 7.x internals with wrong thresholds and pool sizes |
| "Deploy Valkey on Kubernetes" | Suggests Redis Helm charts, not Valkey-specific operators |
| "Use COMMANDLOG to find slow queries" | Doesn't know COMMANDLOG exists (Valkey 8.1+, replaces SLOWLOG) |

These are not edge cases. These are the most common questions developers ask.

### Web docs don't solve this

valkey.io has solid documentation - 520 pages covering commands, topics, and guides. But web documentation and AI skills serve different purposes:

| | Web docs (valkey.io) | AI skills |
|---|---------------------|-----------|
| **Consumed by** | Humans browsing a website | AI assistants loading context |
| **Discovery** | Human clicks sidebar, uses search | AI matches trigger phrase to user query |
| **Scope** | Full pages, multiple topics | One topic per file, 100-300 lines |
| **Format** | HTML with navigation, images, links | Markdown with frontmatter triggers |
| **Loading** | Human reads relevant parts | AI loads entire file into prompt window |
| **Cross-referencing** | Hyperlinks to other pages | Relative paths AI can follow programmatically |
| **Verification** | Editorial review | Verified against actual source code |
| **Freshness** | Manual updates | CI watches upstream releases, opens issues when versions change |

Web docs and AI skills are complementary. Web docs serve developers who browse. AI skills serve developers who ask their AI assistant.

### Redis already invested in this

Redis published `redis/agent-skills` in January 2026. It contains 29 rules covering best practices for data structures, connections, Redis Query Engine, vector search, and semantic caching.

Valkey has no equivalent. This means when a developer's AI assistant needs to answer a Valkey question, it has:
- Redis skills available (if installed) - wrong for Valkey-specific features
- Redis training data - outdated for Valkey's diverged codebase
- No Valkey skills - no way to provide correct answers

## What valkey-skills Provides

204 source-verified reference files organized into 15 skills, structured for AI consumption. Every claim verified against actual Valkey C source code, GLIDE Rust core, and official documentation.

### Core coverage

**valkey** (39 reference files) - for application developers:
- All major command groups with syntax, complexity, and code examples
- 9 application patterns: caching, sessions, locks, rate limiting, queues, leaderboards, counters, pub/sub, search/autocomplete
- Best practices: keys, memory, performance, persistence, cluster, high availability
- Valkey-specific features: SET IFEQ/DELIFEQ, hash field TTL, cluster enhancements, polygon geo queries
- Module commands: JSON, Bloom, Search
- Client overview with feature comparison across GLIDE, valkey-go, redis-py, ioredis, Jedis, Lettuce
- Anti-patterns quick reference
- Redis migration guide

**valkey-dev** (59 reference files) - for server contributors:
- Architecture: event loop, command dispatch, networking, RESP protocol
- Data structures: SDS, quicklist, listpack, skiplist, rax, hashtable (new), dict (legacy)
- Memory: zmalloc, defragmentation, lazy-free, eviction internals
- Threading: I/O threads, BIO, pipeline prefetch
- Replication: overview, dual-channel replication
- Cluster: overview, failover protocol, slot migration
- Persistence: RDB and AOF internals
- Modules API: overview, types/commands, Rust SDK
- Valkey-specific: kvstore, object lifecycle, RDMA transport, vset
- Testing: TCL tests, unit tests, CI pipeline
- Contributing: workflow, governance

**valkey-ops** (52 reference files) - for operators:
- Deployment: install, Docker, bare-metal
- Kubernetes: Helm, operators, StatefulSet, tuning
- Sentinel: architecture, deployment runbook, split-brain
- Cluster: setup, resharding, operations, consistency
- Persistence: RDB, AOF, backup/recovery
- Replication: setup, tuning, safety
- Security: ACL, TLS, hardening, command renaming
- Monitoring: Prometheus, Grafana, alerting, metrics, COMMANDLOG
- Performance: I/O threads, memory, latency, defrag, durability, client-caching
- Troubleshooting: OOM, replication lag, slow commands, cluster partitions, diagnostics
- Upgrades: compatibility matrix, rolling upgrade procedure, Redis migration
- Production checklist

**valkey-ecosystem** (28 reference files) - for evaluators and integrators:
- Client landscape: decision framework, per-language guides (Python, Java, Node.js, Go, others)
- Modules: JSON, Bloom, Search (with feature comparison vs Redis), module gaps analysis
- Managed services: AWS (ElastiCache, MemoryDB), GCP (Memorystore), Aiven, Percona, 10+ providers with comparison matrix
- Monitoring: Prometheus/Grafana setup, GUI tools, monitoring platforms
- Tools: Docker, Kubernetes, CI/CD, Infrastructure as Code, migration, security scanning, testing, AI/ML patterns, CLI/benchmarking, framework integrations (Spring, Django, Rails, Laravel, Sidekiq)
- Community overview

**GLIDE skills** (26 shared + 7 per-language) - for GLIDE users:
- Shared architecture, connection model, cluster topology
- Features: batching, PubSub, scripting, OpenTelemetry, AZ affinity, TLS, compression, streams, server modules
- Per-language API reference: Python, Java, Node.js, Go, C#, PHP, Ruby
- Migration guides: from redis-py, ioredis, Jedis, Lettuce, go-redis, StackExchange.Redis
- Best practices: performance, error handling, production, Spring integration

### Quality controls

- Source-verified against actual Valkey C source and GLIDE Rust core (not just web docs)
- Multi-agent review: 5 independent critics per skill with fix-validation
- Cross-file link verification: 204 internal cross-references validated
- Neutrality: documents what each project offers without positioning against Redis
- CI pipelines: agnix lint (0 errors), link-check, version-watch (weekly checks against upstream releases)

### Distribution

Works with every major AI coding tool:

```
npx skills add avifenesh/valkey-skills
```

Tested and validated on Claude Code, Codex, OpenCode, Cline, GitHub Copilot, Junie, and Amp. Also works with Cursor and Kiro via manual install.

## Options

### Option A: Full adoption under valkey-io

Move the entire repository to the Valkey organization. All 15 skills become official Valkey AI reference materials.

**What Valkey gets:**
- Immediate AI skills coverage across the full ecosystem
- Parity with (and significantly beyond) Redis agent-skills
- Version-watch CI already tracks Valkey/GLIDE releases
- Community can contribute via PRs
- Listed under the official org for discoverability

**Maintenance:** version-watch CI opens issues when upstream releases happen. Updates are targeted to the changed areas (not full rewrites).

### Option B: Core server skills under valkey-io, GLIDE skills separate

Move valkey, valkey-dev, valkey-ops, and valkey-ecosystem to valkey-io. GLIDE and glide-mq skills remain maintained separately.

**What Valkey gets:**
- Covers server, internals, operations, and ecosystem
- GLIDE skills evolve with their own release cadence
- Cleaner ownership boundaries

**What stays separate:** GLIDE per-language skills (7), shared GLIDE skill, glide-mq skills (3)

### Option C: Application and ecosystem skills only

Move valkey and valkey-ecosystem to valkey-io. Server internals (valkey-dev) and operations (valkey-ops) remain community-maintained.

**What Valkey gets:**
- Covers the primary developer audience (app developers and evaluators)
- Lowest maintenance burden
- 67 reference files (vs 204 total)

**What stays separate:** valkey-dev (59 files), valkey-ops (52 files), all GLIDE skills

### Option D: Reference as community resource

Link to valkey-skills from valkey.io as a recommended community resource. No repository move.

**What Valkey gets:**
- Zero maintenance effort
- Developers can still discover and install the skills
- Skills remain community-maintained and updated

### Option E: Fork as a starting point

Use the content as a base for official Valkey skills, adapting structure and voice to Valkey project standards.

**What Valkey gets:**
- Full control over content, structure, and presentation
- Can integrate with valkey.io documentation pipeline
- Can rename, reorganize, or extend as needed

**Effort:** Initial adaptation + ongoing maintenance
