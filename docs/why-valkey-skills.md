# Why Valkey Needs AI Skills

## The Problem

AI coding assistants are the primary interface for a growing number of developers. When a developer asks Claude, Cursor, Copilot, or Codex to "set up a caching layer with Valkey," the assistant draws from its training data - which is overwhelmingly Redis-centric.

### Training data imbalance

Redis has 15+ years of documentation, blog posts, Stack Overflow answers, tutorials, and books. AI models have deeply internalized Redis patterns, APIs, and conventions.

Valkey forked from Redis in March 2024. Its documentation (520 pages on valkey.io) is a fraction of what Redis has accumulated. Even when the answer is identical (most commands are compatible), AI assistants often:

- Reference redis-py instead of valkey-glide
- Suggest Redis Stack modules instead of valkey-search / valkey-json / valkey-bloom
- Miss Valkey-specific features entirely (SET IFEQ, DELIFEQ, hash field TTL, atomic slot migration)
- Use outdated patterns (SLOWLOG instead of COMMANDLOG, old encoding thresholds)
- Default to ioredis/Jedis instead of the official GLIDE client

### The GLIDE knowledge gap

Valkey GLIDE is a new client with no precedent in training data. AI models cannot generate correct GLIDE code without guidance because:

- The API differs from redis-py, ioredis, and Jedis (e.g., `exec()` not `run()`, `Batch` not `Transaction`, tuple-based xadd, message-first publish)
- Each language has its own idioms (Python uses `List[Tuple]`, Java uses `CompletableFuture`, Go uses `Result[T]`)
- Features like AZ Affinity, IAM auth, and OpenTelemetry have no equivalent in other clients
- Connection model is fundamentally different (single multiplexed connection vs connection pools)

Without skills, an AI asked to "use GLIDE with Python" will fabricate API calls based on redis-py patterns. The code will look plausible but won't compile.

### The operations gap

Valkey 8.x and 9.x introduced significant operational changes:

- I/O threading model overhaul
- Dual-channel replication
- Atomic slot migration (replacing key-by-key)
- New Sentinel ACL requirements (+failover)
- Hash field expiration (11 new commands)
- COMMANDLOG replacing SLOWLOG

An operator asking an AI assistant "how do I upgrade from Redis to Valkey 9.0" gets generic advice that misses these changes. The Valkey-specific upgrade path, bug workarounds (9.0.0-9.0.1 hash field expiration issues), and new configuration options are absent from training data.

## What Exists Today

| Resource | Scope | AI-Optimized? |
|----------|-------|---------------|
| valkey.io docs (520 pages) | Commands, topics, blog posts | No - web docs, not structured for RAG |
| GLIDE repo READMEs | Installation, basic examples | No - per-language, no cross-reference |
| GLIDE API docs (generated) | Method signatures | No - auto-generated, no patterns or migration guides |
| Redis agent-skills (29 rules) | Redis best practices | Yes - but Redis-specific, no Valkey content |
| Stack Overflow | Q&A | No - mostly Redis-tagged, Valkey questions sparse |

No AI skills exist for Valkey. There are no structured, RAG-optimized reference materials designed for AI assistants to use when helping developers build with Valkey.

## What valkey-skills Provides

### Coverage

| Skill | Reference Files | Audience |
|-------|----------------|----------|
| valkey | 39 | Application developers - commands, patterns, best practices |
| valkey-dev | 59 | Server contributors - C source internals, architecture |
| valkey-ops | 52 | Operators - deployment, monitoring, security, upgrades |
| valkey-glide | 26 | GLIDE shared architecture, features, migration |
| valkey-ecosystem | 28 | Modules, managed services, tools |
| 7 per-language GLIDE | 7 | Python, Java, Node.js, Go, C#, PHP, Ruby APIs |
| glide-mq (3 skills) | 3 | Message queue development and migration |

204 reference files, verified against actual source code (Valkey C source, GLIDE Rust core, official documentation).

### What this means in practice

**Without skills** - developer asks "how do I use Valkey streams with GLIDE in Python":
- AI generates redis-py code (wrong client)
- Or fabricates GLIDE API calls based on redis-py patterns (wrong API)
- xadd uses dict format (wrong - GLIDE uses `List[Tuple]`)
- publish uses channel-first (wrong - GLIDE uses message-first)

**With skills** - same question:
- AI loads valkey-glide-python skill
- Routes to the Streams section
- Generates correct `xadd` with `List[Tuple[str, str]]` format
- Correct `publish(message, channel)` order
- Includes consumer group patterns with `xreadgroup`

### Comparison with Redis agent-skills

| Aspect | redis/agent-skills | valkey-skills |
|--------|-------------------|---------------|
| Skills | 1 | 15 |
| Reference content | 29 rules (~50 lines each) | 204 docs (~250 lines each) |
| Total content | ~1,500 lines | ~51,000 lines |
| Server internals | None | 59 docs verified against C source |
| Operations | None | 52 docs (k8s, monitoring, security, upgrades) |
| Per-language APIs | Python + Java snippets | 7 dedicated per-language skills |
| Client migration | None | 6 migration guides |
| Managed services | None | AWS, GCP, Aiven, 10+ providers |
| Source verification | Web docs | Actual C/Rust source code |

Redis invested in AI skills for their developer community. Valkey developers currently have no equivalent.

### Quality

Every claim in valkey-skills is verified against actual source code - not just web documentation. The build process includes:

- Multi-agent review (5 independent critics per skill)
- Per-language API validation against GLIDE Rust FFI source
- Cross-file link verification (204 cross-references validated)
- Neutrality review (23 instances of competitive language identified and removed)
- CI: agnix lint, link-check, version-watch for upstream releases

### Distribution

Works with every major AI coding tool:

| Method | Command |
|--------|---------|
| Agent Skills CLI | `npx skills add avifenesh/valkey-skills` |
| Claude Code | `/plugin marketplace add avifenesh/valkey-skills` |
| Manual | `git clone` + copy to tool's skills directory |

Supports Claude Code, Codex, OpenCode, Cursor, Kiro, Cline, GitHub Copilot, Junie, and Amp.

## The Opportunity

AI coding assistants are becoming the default way developers discover and learn APIs. When a developer asks their assistant about caching, queuing, or session management, the assistant's knowledge of Valkey directly influences whether they choose Valkey for their project.

Redis recognized this - they published agent-skills in January 2026. Valkey currently has no equivalent, which means AI assistants default to recommending Redis patterns and clients.

valkey-skills closes this gap with significantly more depth and breadth than what Redis offers. It ensures that when developers ask AI assistants about Valkey, they get accurate, current, verified answers - not Redis approximations.
