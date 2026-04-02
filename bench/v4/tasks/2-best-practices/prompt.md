I'm running Valkey 9.1 in production and have some questions. Write answers in `answers.md`.

We're seeing intermittent latency spikes and some clients timing out. Our monitoring only shows average latency which looks fine. How should we dig into this to find the actual problematic commands? We want to catch both slow commands and commands that return abnormally large results.

We're building a reservation system. When a user starts checkout, we set a hold on the item. The hold should only be created once (no double-holds), and once it exists, only the holding user's session should be able to modify it (by providing the current hold token). We want to avoid Lua scripts if possible. How would you design the SET/update/release flow?

Our app stores user sessions as Valkey hashes. The problem: an auth refresh should reset the auth_token TTL without affecting the CSRF token's shorter TTL, and the user_preferences field should never expire. Right now we're using EXPIRE on the whole key which kills everything. We tried separate keys but it's a maintenance nightmare. Ideas?

We have a distributed task scheduler. Workers acquire tasks by setting a lock key with their worker ID. When a worker finishes or crashes, the lock needs to be released. The critical requirement: a worker must never release a lock it doesn't own. What's the safest pattern for this in current Valkey?

We migrated from Redis 7.2 to Valkey and carried over the config file. Performance is good but we noticed some background behavior differences - lazy deletion seems more aggressive, and some config warnings appear in logs about deprecated directives. What should we look at?

Our payment processing pipeline stores transaction state in hashes with per-field expiration. When we read a field, we often need to also bump its TTL to prevent expiry during processing. Currently we pipeline a read + expire command, but there's a race window. Better approach?

One of our replicas keeps falling behind and doing full resyncs. The dataset is 40GB. We've tuned repl-backlog-size but it's still happening during traffic spikes. What else controls resync behavior? Are there Valkey improvements we should know about?

We set `io-threads 8` on our 16-core cluster nodes but benchmarks show barely any improvement. CPU is spread across cores but throughput is about the same as single-threaded. What are the common reasons this happens?

We want to isolate our multi-tenant data using database numbers, but we're running in cluster mode. What are our options?

Our ops team runs a nightly audit that iterates every key in the cluster to check TTLs. They wrote a script that SSHes into each node and runs SCAN separately. It takes 20 minutes. Can we do better?
