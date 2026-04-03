# Listpack - Compact Sequential Encoding

Use when you need a compact, contiguous-memory container for small collections. Listpack is the small-encoding for Lists, Hashes, Sets, and Sorted Sets.

Standard listpack implementation, same as Redis 7.x. No Valkey-specific changes to the data structure itself.

Source: `src/listpack.c`, `src/listpack.h`. Header: 6 bytes (4-byte total_bytes + 2-byte count). Max size: 1 GB. Entries store integers (2-10 bytes) or strings (variable) with backlen for reverse traversal. All operations are O(n) except length (O(1) if count <= 65535).
