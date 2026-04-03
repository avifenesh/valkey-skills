# Benchmark Results

Each task runs twice - once with skills loaded, once without. Isolated workspaces, no web access, no shared context. Tested on Sonnet 4.6 and Opus 4.6 (Bedrock).

## Tested Skills

### valkey - Application development

**What was tested**: 10 real-world Valkey 9.x scenarios (diagnosing slow commands, feature flags, per-field session TTLs, lock release, config migration from Redis 7.2, replication issues, I/O thread tuning, multi-database clustering, cluster-wide iteration).

**Why skills help**: Without the skill, models answer with Redis 7.x patterns. With it, they use Valkey-specific commands (COMMANDLOG, SET IFEQ, HSETEX/HGETEX, DELIFEQ, CLUSTERSCAN) that don't exist in Redis.

| Model | Without Skill | With Skill | Improvement |
|-------|--------------|------------|-------------|
| Sonnet 4.6 | 6/14 | **10/14** | +4 correct answers |
| Opus 4.6 | 5/14 | **10/14** | +5 correct answers |

### valkey-dev - Server internals

**What was tested**: Find and fix a cluster split-brain bug introduced in Valkey source code (~200 C files). Agent receives only symptoms, must locate the root cause and produce a compiling fix.

**Why skills help**: The skill maps the server architecture - where cluster epoch resolution lives, how failover works, which functions handle collision detection. Without it, the agent searches blind.

| Model | Without Skill | With Skill | Improvement |
|-------|--------------|------------|-------------|
| Sonnet 4.6 | 8/12 | **11/12** | +3 checks passed |

### valkey-ops - Operations

**What was tested**: Two tasks. (1) Create a Helm values file for a 6-node Valkey cluster on Kubernetes with TLS, auth, persistence, and resource limits - validated with `helm template`. (2) Fix a broken valkey.conf migrated from Redis 7.2 (15 problems) and answer 5 operational questions.

**Why skills help**: The skill provides exact Helm chart repo URLs, value key paths, and Valkey-specific config directives (COMMANDLOG replacing SLOWLOG, deprecated io-threads-do-reads, lazyfree defaults). Models can't guess Bitnami chart values or renamed config parameters.

| Model | Task | Without Skill | With Skill | Improvement |
|-------|------|--------------|------------|-------------|
| Opus 4.6 | Helm chart | 16/19, $2.50 | **18/19**, $1.57 | +2 checks, 37% cheaper |
| Sonnet 4.6 | Config audit | 16/22 | **17/22** | +1 check |

## Untested Skills (Expected High Value)

These skills follow the same pattern as the tested ones - they provide API details that don't exist in model training data. Migration skills are particularly strong candidates because GLIDE client APIs differ significantly from the Redis clients they replace.

| Skill | Why Expected to Help |
|-------|---------------------|
| **migrate-redis-py** | GLIDE Python has different API shapes: `Batch` not `pipeline`, `ExpirySet` not `ex=`, list args not varargs, bytes returns (no `decode_responses`). Models will write redis-py patterns that don't compile. |
| **migrate-ioredis** | GLIDE Node.js reverses `publish(message, channel)` arg order, requires creation-time PubSub config, uses `ClusterScanCursor`. Models will write ioredis code. |
| **migrate-jedis** | GLIDE Java uses `CompletableFuture`, different builder patterns, `Batch` API. Zero-code-change compatibility layer exists but native rewrite needs the skill. |
| **migrate-go-redis** | GLIDE Go uses `Result[T].IsNil()` instead of `redis.Nil` error sentinel, `config.NewClientConfiguration()` builder instead of `redis.Options{}`. |
| **valkey-glide-*** | Per-language GLIDE skills (7 languages). Each has unique API patterns not in training data - especially Go, C#, PHP, Ruby which are newer clients. |
| **glide-mq** | glide-mq is a new library with minimal public training data. Connection format, `upsertJobScheduler()`, removed `defaultJobOptions` - all undiscoverable without the skill. |
| **spring-data-valkey** | Maven coordinates (`io.valkey.springframework.boot`), `os-maven-plugin` for native bindings, `spring.data.valkey.*` property prefix, `ValkeyTemplate` - all impossible to guess. |
| **valkey-bloom-dev** | Contributor skill for Rust bloom filter module. Teaches BloomObject internals, command registration patterns, bincode serialization. |
| **valkey-search-dev** | Contributor skill for C++ search module. Teaches HNSW/FLAT index internals, query engine, cluster coordinator, build system. |

## Skills Removed (No Value)

valkey-module-dev (Rust crate in training data), valkey-json-dev (C++ navigable without skills), valkey-modules (same query syntax as RediSearch).
