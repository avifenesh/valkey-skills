# Benchmarks

Tested on Sonnet 4.6 and Opus 4.6 (Bedrock). Isolated workspaces - no web access, no shared context, no repository metadata. Each condition ran multiple times for reliability.

## Results

### valkey (application development)

10 Valkey 9.x problem-solving scenarios. The skill teaches commands that don't exist in training data: `COMMANDLOG`, `SET IFEQ`, `HSETEX`/`HGETEX`, `DELIFEQ`, `CLUSTERSCAN`. Without it, models default to Redis 7.x answers.

| Model | Without | With | Delta |
|-------|---------|------|-------|
| Sonnet 4.6 | 6/14 | **10/14** | **+4** |
| Opus 4.6 | 5/14 | **10/14** | **+5** |

### valkey-dev (server internals)

Find and fix a cluster split-brain bug in ~200 C source files. Only symptoms given - no hints about where to look. The skill maps the server architecture so the agent navigates directly instead of searching blind.

| Model | Without | With | Delta |
|-------|---------|------|-------|
| Sonnet 4.6 | 8/12 | **11/12** | **+3** |

### valkey-ops (operations)

Two tasks: (1) Helm chart for a 6-node Valkey cluster on K8s with TLS, auth, persistence. (2) Config audit of a valkey.conf migrated from Redis 7.2. The skill provides exact chart values, renamed config directives, and Valkey-specific defaults that models can't guess.

| Model | Task | Without | With | Delta |
|-------|------|---------|------|-------|
| Opus 4.6 | Helm chart | 16/19, $2.50 | **18/19**, $1.57 | **+2**, 37% cheaper |
| Sonnet 4.6 | Config audit | 16/22 | **17/22** | **+1** |

### glide-mq (message queues)

Tested across multiple examples. With the skill, code compiled and ran correctly. Without it, models invented non-existent APIs and produced code that failed at runtime.

## Not Yet Tested

Migration skills teach the exact API differences between Redis clients and GLIDE. GLIDE has different method signatures, argument orders, and patterns - code written from Redis knowledge won't compile.

| Skill | What models get wrong without it |
|-------|--------------------------------|
| **migrate-redis-py** | `pipeline()` instead of `Batch`, `ex=60` instead of `ExpirySet`, varargs instead of list args |
| **migrate-ioredis** | `publish(channel, message)` instead of `publish(message, channel)`, runtime PubSub instead of creation-time |
| **migrate-jedis** | Missing `CompletableFuture` patterns, wrong builder API |
| **migrate-go-redis** | `redis.Nil` error instead of `Result[T].IsNil()`, `redis.Options{}` instead of config builder |
| **migrate-lettuce**, **migrate-stackexchange** | Same pattern - GLIDE APIs differ in ways models can't guess |
| **spring-data-valkey** | Wrong Maven coordinates, missing `os-maven-plugin`, wrong property prefix |

## Removed

Three skills were cut after benchmarking showed no improvement:

- **valkey-module-dev** - Rust crate well-known in training data. Models scored 21/21 with and without.
- **valkey-json-dev** - C++ navigable without skills. Actively hurt Opus performance.
- **valkey-modules** (query syntax) - Identical to RediSearch. No knowledge gap to fill.

We don't keep skills that don't earn their place.
