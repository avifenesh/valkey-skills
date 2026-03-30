# RESP Protocol

Use when you need to understand the wire format, how Valkey parses client requests, or differences between RESP2 and RESP3.

---

## Overview

RESP (REdis Serialization Protocol) is the wire protocol used by Valkey. Clients connect over TCP and exchange RESP-encoded messages. Valkey supports two protocol versions:

- **RESP2** (default) - the classic protocol
- **RESP3** - extended protocol with richer types, negotiated via `HELLO 3`

All RESP messages are terminated by `\r\n` (CRLF).

## RESP2 Types

| Prefix | Type | Example | Description |
|--------|------|---------|-------------|
| `+` | Simple String | `+OK\r\n` | Status reply |
| `-` | Error | `-ERR unknown command\r\n` | Error with optional code |
| `:` | Integer | `:1000\r\n` | Signed 64-bit integer |
| `$` | Bulk String | `$3\r\nfoo\r\n` | Binary-safe string with length prefix |
| `$-1` | Null Bulk String | `$-1\r\n` | Null value |
| `*` | Array | `*2\r\n$3\r\nfoo\r\n$3\r\nbar\r\n` | Ordered collection |
| `*-1` | Null Array | `*-1\r\n` | Null array |

### RESP2 Encoding Examples

**Simple command reply:**
```
+OK\r\n
```

**Integer reply (INCR):**
```
:42\r\n
```

**Bulk string reply (GET):**
```
$5\r\nhello\r\n
```

**Array reply (KEYS):**
```
*3\r\n
$3\r\nfoo\r\n
$3\r\nbar\r\n
$3\r\nbaz\r\n
```

**Nested array (EXEC):**
```
*2\r\n
+OK\r\n
:1\r\n
```

## RESP3 Types

RESP3 adds these types on top of RESP2:

| Prefix | Type | Example | Description |
|--------|------|---------|-------------|
| `_` | Null | `_\r\n` | Unified null (replaces `$-1` and `*-1`) |
| `,` | Double | `,3.14\r\n` | IEEE 754 double |
| `#` | Boolean | `#t\r\n` / `#f\r\n` | True or false |
| `(` | Big Number | `(3492890328409238509324850943850943825024385\r\n` | Arbitrary precision integer |
| `=` | Verbatim String | `=15\r\ntxt:Some string\r\n` | Bulk string with type hint (3-char prefix + `:`) |
| `%` | Map | `%2\r\n+key1\r\n:1\r\n+key2\r\n:2\r\n` | Key-value pairs |
| `~` | Set | `~3\r\n+a\r\n+b\r\n+c\r\n` | Unordered unique elements |
| `>` | Push | `>3\r\n+message\r\n+channel\r\n+data\r\n` | Out-of-band push message |
| `\|` | Attribute | `\|1\r\n+key\r\n+val\r\n` | Metadata preceding another type |

### RESP2 vs RESP3 Compatibility

The server adapts reply encoding based on the client's negotiated protocol. Key differences visible in the source (`networking.c`):

| Reply Type | RESP2 Encoding | RESP3 Encoding |
|------------|---------------|----------------|
| Null | `$-1\r\n` | `_\r\n` |
| Boolean | `:0`/`:1` | `#f`/`#t` |
| Double | `$N\r\n<string>\r\n` (bulk string) | `,<double>\r\n` |
| Map | `*N\r\n` (flat array, 2x length) | `%N\r\n` |
| Set | `*N\r\n` (array) | `~N\r\n` |
| Big Number | `$N\r\n<digits>\r\n` (bulk string) | `(<digits>\r\n` |
| Verbatim | `$N\r\n<text>\r\n` (bulk string) | `=N\r\ntxt:<text>\r\n` |
| Push | N/A (inline in data) | `>N\r\n...` |

Source evidence from `networking.c`:

```c
void addReplyNull(client *c) {
    if (c->resp == 2) {
        addReplyProto(c, "$-1\r\n", 5);
    } else {
        addReplyProto(c, "_\r\n", 3);
    }
}

void addReplyBool(client *c, int b) {
    if (c->resp == 2) {
        addReply(c, b ? shared.cone : shared.czero);
    } else {
        addReplyProto(c, b ? "#t\r\n" : "#f\r\n", 4);
    }
}

void addReplyMapLen(client *c, long length) {
    int prefix = c->resp == 2 ? '*' : '%';
    if (c->resp == 2) length *= 2;  /* Flatten map to array */
    addReplyAggregateLen(c, length, prefix);
}
```

## Inline Command Format

For interactive use (e.g., telnet), Valkey accepts inline commands - space-separated arguments terminated by `\r\n`:

```
PING\r\n
SET foo bar\r\n
GET foo\r\n
```

Inline commands are parsed by `parseInlineBuffer()` (`networking.c:3348`). The parser splits on spaces using `sdsnsplitargs()` which handles quoted strings and escaped characters.

[NOTE] Inline protocol is only used for client-to-server commands. Replicas always use RESP multibulk. If a replica sends inline protocol, Valkey treats it as a desynchronization bug and rejects it.

## RESP Multibulk (Standard Format)

All client libraries use the multibulk format:

```
*<argc>\r\n
$<len1>\r\n<arg1>\r\n
$<len2>\r\n<arg2>\r\n
...
```

Example - `SET mykey myvalue`:
```
*3\r\n
$3\r\nSET\r\n
$5\r\nmykey\r\n
$7\r\nmyvalue\r\n
```

## How Valkey Parses RESP

### Protocol Detection (`networking.c:3858`)

```c
void parseInputBuffer(client *c) {
    if (!c->reqtype) {
        if (c->querybuf[c->qb_pos] == '*') {
            c->reqtype = PROTO_REQ_MULTIBULK; /* value: 2 */
        } else {
            c->reqtype = PROTO_REQ_INLINE;    /* value: 1 */
        }
    }
    if (c->reqtype == PROTO_REQ_INLINE) {
        parseInlineBuffer(c);
    } else {
        parseMultibulkBuffer(c);
    }
}
```

[NOTE] The detection checks the first byte: `*` means multibulk, anything else means inline.

### Multibulk Parsing (`networking.c:3478`)

The parser is incremental - it can resume when more data arrives:

1. Parse `*<count>\r\n` to get `multibulklen` (number of arguments)
2. For each argument, parse `$<len>\r\n`, then read `len` bytes + `\r\n`
3. Each argument becomes an `robj` in `c->argv[]`

For large arguments (>32 KB, `PROTO_MBULK_BIG_ARG`), the parser requests exactly the remaining bytes from the network layer. This avoids reading excess data and allows zero-copy: the query buffer SDS can become the argument object directly without memcpy.

### Pipelined Parsing

After parsing one complete command, if more data begins with `*`, the parser continues into the command queue (`cmdQueue`) up to 512 pipelined commands. Each queued command stores its own `argc`, `argv`, and parse flags.

## Buffer Size Constants

| Constant | Value | Defined at | Purpose |
|----------|-------|------------|---------|
| `PROTO_IOBUF_LEN` | 16 KB | `server.h:209` | Default network read size |
| `PROTO_REPLY_CHUNK_BYTES` | 16 KB | `server.h:210` | Static reply buffer and reply list node size |
| `PROTO_MBULK_BIG_ARG` | 32 KB | `server.h:212` | Threshold for "big argument" optimization |
| `PROTO_INLINE_MAX_SIZE` | 64 KB | `server.h` | Maximum inline command length |
| `PROTO_REQ_INLINE` | 1 | `server.h:393` | Inline request type flag |
| `PROTO_REQ_MULTIBULK` | 2 | `server.h:394` | Multibulk request type flag |

## Push Protocol (Client-Side Caching)

RESP3 introduces push messages (`>` prefix) for server-initiated notifications. The primary use case is client-side caching invalidation.

When a client enables tracking (`CLIENT TRACKING ON`), Valkey remembers which keys the client has read. When those keys are modified by another client, Valkey sends a push invalidation:

```
>2\r\n
$10\r\ninvalidate\r\n
*1\r\n
$5\r\nmykey\r\n
```

Push messages are interleaved with regular replies but distinguished by the `>` prefix. In RESP2, invalidation messages are delivered through a dedicated Pub/Sub channel (`__redis__:invalidate`).

In the source, push messages are sent via `addReplyPushLen()` (`networking.c:1376`):

```c
void addReplyPushLen(client *c, long length) {
    serverAssert(c->resp >= 3);
    serverAssertWithInfo(c, NULL, c->flag.pushing);
    addReplyAggregateLen(c, length, '>');
}
```

Push messages are deferred during command execution and flushed after the command reply completes, preventing interleaving within a single reply. This is managed by `server.pending_push_messages` and the `c->flag.pushing` bitfield.

### Broadcast Mode

In broadcast mode (`CLIENT TRACKING ON BCAST PREFIX ...`), the server does not track per-client key reads. Instead, it broadcasts invalidation for any key matching registered prefixes. Broadcast invalidations are sent from `trackingBroadcastInvalidationMessages()` in `beforeSleep()`.

## See Also

- [networking.md](networking.md) - Read/write buffer management
- [command-dispatch.md](command-dispatch.md) - What happens after parsing
- [../valkey-specific/object-lifecycle.md](../valkey-specific/object-lifecycle.md) - Each parsed argument becomes an `robj` in `c->argv[]`
