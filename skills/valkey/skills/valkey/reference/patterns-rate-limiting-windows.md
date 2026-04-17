# Rate Limiting: Window-Based Patterns

Use when you need a brief orientation on window-based rate limiting approaches before choosing an implementation.

## Overview

Three standard patterns exist, all using generic Redis/Valkey commands:

- **Fixed window** - `INCR` + `EXPIRE` on a per-window key. Simple, O(1), but allows 2x burst at window boundaries.
- **Sliding window counter** - two window keys weighted by elapsed ratio. Approximates a true sliding window with O(1) ops and low memory.
- **Sliding window log** - sorted set of timestamps per user. Exact, but O(N) memory and higher CPU at scale.

All three are standard Redis patterns. A model already trained on Redis knows the implementation.

## Beyond Window-Based

For production rate limiting on Valkey, see `patterns-rate-limiting-advanced.md`, which covers:

- **Token bucket** (Lua script) - bursts up to a cap, sustained refill rate
- **Per-endpoint rate limits in one hash** using Valkey 9.0+ hash-field TTL - separate windows for each API route under a single user key
