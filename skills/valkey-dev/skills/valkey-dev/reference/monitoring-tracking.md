# Client Tracking

Use when implementing client-side caching, understanding invalidation messages, or debugging cache invalidations.

Standard CLIENT TRACKING with two modes: default (key-based via TrackingTable rax) and broadcasting (prefix-based via PrefixTable rax). RESP3 push invalidations or RESP2 pubsub redirect on `__redis__:invalidate` channel. OPTIN/OPTOUT/NOLOOP flags. Table eviction via `tracking_table_max_keys`. Broadcast invalidations batched per event loop cycle.

Source: `src/tracking.c`
