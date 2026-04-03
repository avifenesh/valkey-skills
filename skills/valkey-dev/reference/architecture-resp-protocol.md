# RESP Protocol

Use when you need to understand the wire format, how Valkey parses client requests, or differences between RESP2 and RESP3.

Standard RESP2/RESP3 protocol, identical to Redis. No Valkey-specific changes to the wire format.

Source: `src/networking.c`. Key constants: `PROTO_IOBUF_LEN` (16 KB), `PROTO_REPLY_CHUNK_BYTES` (16 KB), `PROTO_MBULK_BIG_ARG` (32 KB).
