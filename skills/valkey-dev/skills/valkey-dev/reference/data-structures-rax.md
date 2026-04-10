# Rax - Radix Tree

Use when you need a memory-efficient, prefix-compressed tree for byte-string keys with ordered iteration. Used by Streams (consumer groups, stream IDs) and cluster fail_reports tracking.

Standard radix tree implementation, same as Redis. No Valkey-specific changes.

Source: `src/rax.c`, `src/rax.h`. Lookup is O(k) where k is key length. Compressed nodes collapse single-child chains. Used primarily by Streams (stream ID index, consumer groups, PEL) and cluster fail reports.
