# Multi-Language Microservices with Shared Valkey

Build three microservices that share a single Valkey instance. Each service is in a different language and uses the valkey-glide client library for that language.

## Shared Infrastructure

All three services connect to the same Valkey server at `localhost:6379`. Each service uses its own key prefix to avoid collisions.

## Service 1: Leaderboard (Go) - `leaderboard-go/`

A gaming leaderboard service using sorted sets.

Implement these functions in `main.go`:
- `NewLeaderboard(client)` - constructor that stores the GLIDE client
- `AddScore(ctx, player, score)` - add or update a player's score using ZADD
- `GetTop(ctx, n)` - get the top N players with highest scores, returning players in descending score order
- `GetRank(ctx, player)` - get a player's rank (0-based, highest score = rank 0), return -1 if player not found
- `RemovePlayer(ctx, player)` - remove a player from the leaderboard

The skeleton files (`go.mod`, `main.go`, `leaderboard_test.go`) are provided. Fill in the TODO sections in `main.go`. Tests are pre-written and must pass.

## Service 2: Chat (Node.js/TypeScript) - `chat-nodejs/`

A real-time chat service with message history.

Implement these functions in `src/chat.ts`:
- `ChatService` class with constructor that takes a GLIDE cluster client and a publisher client
- `sendMessage(channel, sender, text)` - publish a message and store it in history (use a LIST for history, LPUSH + LTRIM to cap at 100)
- `getHistory(channel, count)` - get the last N messages from a channel's history list
- `getActiveChannels()` - return the set of channels that have history

The skeleton files (`package.json`, `tsconfig.json`, `src/chat.ts`, `src/chat.test.ts`) are provided. Fill in the TODO sections in `src/chat.ts`. Tests are pre-written and must pass.

Note: The chat service uses sharded PubSub for real-time delivery. PubSub subscriptions must be configured at client creation time - this is a key design aspect of the GLIDE client.

## Service 3: Background Stats (Python) - `stats-python/`

An async statistics aggregation service using batch operations and Lua scripting.

Implement these functions in `stats.py`:
- `StatsService` class with constructor that takes a GLIDE client
- `record_event(event_type, data)` - store event data in a hash and push the event ID to a type-specific list
- `compute_daily_stats()` - use a batch operation to atomically read multiple event lists and compute counts
- `run_lua_aggregate(keys, args)` - execute a Lua script that aggregates values across multiple keys

The skeleton files (`requirements.txt`, `stats.py`, `test_stats.py`) are provided. Fill in the TODO sections in `stats.py`. Tests are pre-written and must pass.
