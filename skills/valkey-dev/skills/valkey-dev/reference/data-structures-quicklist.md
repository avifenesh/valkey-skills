# Quicklist - Doubly-Linked List of Listpacks

Use when working with the List data type at full encoding. Quicklist combines the memory efficiency of listpack with O(1) push/pop at both ends.

Standard quicklist implementation, same as Redis 7.x. No Valkey-specific changes.

Source: `src/quicklist.c`, `src/quicklist.h`. Each node holds a listpack (or PLAIN for oversized entries). Interior nodes can be LZF-compressed. Default fill: -2 (8 KB nodes). Config: `list-max-listpack-size`, `list-compress-depth`.
