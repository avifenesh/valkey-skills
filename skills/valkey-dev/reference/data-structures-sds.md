# SDS - Simple Dynamic Strings

Use when you need binary-safe strings with O(1) length, preallocation for amortized appends, and C-string compatibility.

Standard SDS implementation, same as Redis. No Valkey-specific changes to the data structure.

Source: `src/sds.c`, `src/sds.h`. Five header variants (TYPE_5 through TYPE_64) selected by string length. Greedy doubling up to 1 MB, then +1 MB. The `flags` byte at `s[-1]` encodes type in 3 low bits; remaining bits available via `sdsGetAuxBit`/`sdsSetAuxBit`.
