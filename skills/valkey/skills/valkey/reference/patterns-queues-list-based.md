# List-Based Queue Patterns

Use when you need a brief orientation on list queues before choosing an implementation.

## Overview

Two standard patterns, both using generic Redis/Valkey list commands:

- **Simple queue** - `LPUSH` to enqueue, `BRPOP` to consume. At-most-once delivery. No acknowledgment. Consumer crash loses the in-flight message.
- **Reliable queue** - `LPUSH` to enqueue, `BLMOVE` to atomically move to a processing list, `LREM` on success. At-least-once delivery. Requires a recovery job to requeue stuck messages.

Both are standard Redis patterns. A model already trained on Redis knows the implementation.

## For Production Use

List queues lack retry counts, dead-letter queues, priority, and scheduling. For production workloads, see `patterns-queues-streams.md`, which covers Valkey Streams (`XADD`/`XREADGROUP`/`XACK`) with consumer groups and built-in pending entry tracking.
