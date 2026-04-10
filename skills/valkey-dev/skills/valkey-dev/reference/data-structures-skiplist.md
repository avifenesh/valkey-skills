# Skiplist - Probabilistic Sorted Structure

Use when working with sorted sets that exceed the listpack threshold.

Standard skiplist implementation. Valkey-specific changes:

- SDS element is embedded directly after the level array in `zskiplistNode` (single allocation per node, improved cache locality) - Valkey 8.1+
- Header node uses unions: `score`/`length` and `backward`/`tail` share storage to save memory
- Level 0 span field repurposed to store node height
- `zskiplist` struct is minimal (just the header node) - length and tail are stored in the header node itself via unions

Source: `src/t_zset.c`, `src/server.h`. Max level: 32. Probability p=0.25 per level. Paired with `hashtable` (not dict) for O(1) ZSCORE lookups.
