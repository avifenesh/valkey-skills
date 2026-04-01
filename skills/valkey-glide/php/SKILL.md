---
name: valkey-glide-php
description: "PHP Valkey GLIDE client - synchronous C extension API (PHP 8.1+), PIE/Composer/PECL install, GlideClient, batching, phpredis compatibility aliases, PubSub, TLS. Not for other languages - see valkey-glide router."
version: 2.0.0
argument-hint: "[API or config question]"
---

# Valkey GLIDE PHP Client

Synchronous PHP client for Valkey built on the GLIDE Rust core via native C extension. GA release (1.0).

**Separate repository:** [valkey-io/valkey-glide-php](https://github.com/valkey-io/valkey-glide-php)

## Routing

| Question | Reference |
|----------|-----------|
| Setup, client creation, TLS, auth, config, read strategy, PHPRedis aliases | [connection](reference/features/connection.md) |
| PubSub, subscribe, publish, pattern subscriptions | [pubsub](reference/features/pubsub.md) |
| Install, API status, platform support, command groups, batching, phpredis compat, limitations | [overview](reference/features/overview.md) |

## Cross-References

- `valkey-glide` skill - shared architecture, cluster topology, connection model
- `valkey` skill - Valkey server commands, data types, patterns
