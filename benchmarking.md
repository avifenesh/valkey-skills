# Benchmark Results

Each task runs with and without skills. Isolated workspaces, no web access, no shared context. Sonnet 4.6 and Opus 4.6 on Bedrock.

## Tested

### valkey

10 Valkey 9.x problem-solving scenarios. Without the skill, models default to Redis 7.x answers. The skill teaches commands that don't exist in Redis: COMMANDLOG, SET IFEQ, HSETEX/HGETEX, DELIFEQ, CLUSTERSCAN.

| Model | Without | With | Delta |
|-------|---------|------|-------|
| Sonnet 4.6 | 6/14 | **10/14** | **+4** |
| Opus 4.6 | 5/14 | **10/14** | **+5** |

### valkey-dev

Find and fix a cluster split-brain bug in ~200 C source files. Only symptoms given. The skill maps the server architecture so the agent navigates to the right code path instead of searching blind.

| Model | Without | With | Delta |
|-------|---------|------|-------|
| Sonnet 4.6 | 8/12 | **11/12** | **+3** |

### valkey-ops

Two tasks: (1) Helm chart for a 6-node Valkey cluster on K8s with TLS, auth, persistence. (2) Fix a broken valkey.conf migrated from Redis 7.2. The skill provides exact chart values, renamed config directives, and Valkey-specific defaults that models can't guess.

| Model | Task | Without | With | Delta |
|-------|------|---------|------|-------|
| Opus 4.6 | Helm | 16/19 $2.50 | **18/19** $1.57 | **+2**, 37% cheaper |
| Sonnet 4.6 | Config | 16/22 | **17/22** | **+1** |

### glide-mq

Tested separately across multiple glide-mq examples. With the skill, code compiled and ran correctly. Without it, models invented non-existent APIs and produced code with runtime errors.

## Not Yet Tested

These skills teach APIs that aren't in model training data. The GLIDE client library has different method signatures, argument orders, and patterns than the Redis clients it replaces - code written from Redis knowledge won't compile.

| Skill | What models get wrong without it |
|-------|--------------------------------|
| **migrate-redis-py** | Writes `pipeline()` instead of `Batch`, `ex=60` instead of `ExpirySet`, varargs instead of list args |
| **migrate-ioredis** | Writes `publish(channel, message)` instead of `publish(message, channel)`, runtime PubSub instead of creation-time |
| **migrate-jedis** | Missing `CompletableFuture` patterns, wrong builder API, no `Batch` class |
| **migrate-go-redis** | Uses `redis.Nil` error instead of `Result[T].IsNil()`, `redis.Options{}` instead of config builder |
| **migrate-lettuce**, **migrate-stackexchange** | Same pattern - GLIDE APIs differ from the source client in ways models can't guess |
| **spring-data-valkey** | Wrong Maven coordinates, missing `os-maven-plugin`, wrong property prefix (`spring.data.redis` vs `spring.data.valkey`) |
| **valkey-glide-*** | Per-language GLIDE skills (7 languages). Newer clients (Go, C#, PHP, Ruby) have especially little training data |

## Removed (No Value)

valkey-module-dev, valkey-json-dev, valkey-modules - models already knew these from training data.
