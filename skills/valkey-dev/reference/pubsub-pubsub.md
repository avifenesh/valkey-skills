# Pub/Sub Subsystem

Use when working on message broadcasting, channel subscriptions, pattern matching, or sharded pub/sub in cluster mode.

Standard pub/sub implementation, same as Redis 7.0+. No Valkey-specific changes.

Source: `src/pubsub.c`. Global and shard channels stored in `kvstore`. Pattern subscriptions in `dict`. Sharded pub/sub scoped to hash slots with `SSUBSCRIBE`/`SPUBLISH`. RESP3 clients get push-type replies (`>`), RESP2 gets arrays.
