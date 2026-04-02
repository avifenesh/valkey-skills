We migrated our Valkey config from a Redis 7.2 deployment and it's a mess. Can you review `valkey.conf` and fix it? It's for a high-throughput session store on a 16-core / 64GB machine running Valkey 9.0.

The config has around 15 problems - deprecated patterns, wrong parameter names, missing features, security holes, bad tuning for session workloads.

Write the fixed config to `valkey-fixed.conf`. It should be a complete, valid config that starts cleanly and is properly tuned for production.

Also answer the 5 questions in `questions.md` - write answers to `answers.md`. Be exact about command names, config params, and what actually exists in Valkey 9.0 vs Redis.

Write `AUDIT.md` explaining what you changed and why.
