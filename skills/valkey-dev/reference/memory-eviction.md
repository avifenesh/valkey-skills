# Eviction Subsystem

Use when working on eviction policies, LRU/LFU approximation, or maxmemory enforcement.

Standard sampling-based eviction with 8 policies (volatile/allkeys x LRU/LFU/TTL/random + noeviction), 16-entry eviction pool, and `performEvictions()` called before every write command. See Redis eviction docs for the base algorithm.

Source: `src/evict.c`, `src/lrulfu.c`
