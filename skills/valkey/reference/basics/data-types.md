# Data Types Quick Reference

Use when looking up Valkey command syntax for strings, hashes, lists, sets, sorted sets, streams, pub/sub, HyperLogLog, bitmaps, geospatial, or key management operations.

Valkey supports all Redis data types. This is a brief listing - for Valkey-specific extensions to these types (IFEQ on strings, HEXPIRE on hashes, GEOSEARCH BYPOLYGON), see the Valkey-Specific Features section.

## Strings
`SET`, `GET`, `MSET`, `MGET`, `INCR`, `DECR`, `INCRBY`, `DECRBY`, `INCRBYFLOAT`, `APPEND`, `STRLEN`, `GETRANGE`, `SETRANGE`, `SETNX`, `GETSET`, `GETDEL`, `GETEX`

**Valkey additions**: `SET key val IFEQ old_val` (conditional update), `DELIFEQ key val` (conditional delete)

## Hashes
`HSET`, `HGET`, `HMGET`, `HGETALL`, `HDEL`, `HEXISTS`, `HLEN`, `HKEYS`, `HVALS`, `HINCRBY`, `HINCRBYFLOAT`, `HSETNX`, `HRANDFIELD`, `HSCAN`

**Valkey additions**: `HSETEX` (set with TTL), `HGETEX` (get and set/refresh TTL), `HGETDEL` (get and delete), `HEXPIRE`/`HPEXPIRE` (per-field TTL), `HTTL`/`HPTTL`, `HEXPIRETIME`, `HPERSIST`

## Lists
`LPUSH`, `RPUSH`, `LPOP`, `RPOP`, `LRANGE`, `LINDEX`, `LLEN`, `LPOS`, `LSET`, `LINSERT`, `LTRIM`, `LMOVE`, `BLPOP`, `BRPOP`, `BLMOVE`, `LMPOP`, `BLMPOP`

## Sets
`SADD`, `SREM`, `SISMEMBER`, `SMISMEMBER`, `SMEMBERS`, `SCARD`, `SRANDMEMBER`, `SPOP`, `SINTER`, `SUNION`, `SDIFF`, `SINTERCARD`, `SINTERSTORE`, `SUNIONSTORE`, `SDIFFSTORE`, `SSCAN`

## Sorted Sets
`ZADD`, `ZREM`, `ZSCORE`, `ZRANK`, `ZREVRANK`, `ZRANGE`, `ZREVRANGE`, `ZRANGEBYSCORE`, `ZRANGEBYLEX`, `ZINCRBY`, `ZCARD`, `ZCOUNT`, `ZLEXCOUNT`, `ZPOPMIN`, `ZPOPMAX`, `BZPOPMIN`, `BZPOPMAX`, `ZRANDMEMBER`, `ZMSCORE`, `ZRANGESTORE`, `ZDIFF`, `ZINTER`, `ZUNION`, `ZINTERCARD`, `ZSCAN`

## Streams
`XADD`, `XREAD`, `XRANGE`, `XREVRANGE`, `XLEN`, `XTRIM`, `XINFO`, `XGROUP CREATE`, `XREADGROUP`, `XACK`, `XPENDING`, `XCLAIM`, `XAUTOCLAIM`, `XDEL`

## Pub/Sub
`SUBSCRIBE`, `UNSUBSCRIBE`, `PUBLISH`, `PSUBSCRIBE`, `PUNSUBSCRIBE`, `SSUBSCRIBE`, `SUNSUBSCRIBE`, `SPUBLISH`, `PUBSUB CHANNELS/NUMSUB/NUMPAT`

## HyperLogLog
`PFADD`, `PFCOUNT`, `PFMERGE`

## Bitmaps
`SETBIT`, `GETBIT`, `BITCOUNT`, `BITOP`, `BITPOS`, `BITFIELD`

## Geospatial
`GEOADD`, `GEOPOS`, `GEODIST`, `GEOHASH`, `GEOSEARCH`, `GEOSEARCHSTORE`

**Valkey additions**: `GEOSEARCH ... BYPOLYGON` (arbitrary polygon region matching)

## Key Management
`DEL`, `UNLINK` (async), `EXISTS`, `TYPE`, `RENAME`, `RENAMENX`, `COPY`, `OBJECT ENCODING/IDLETIME/FREQ/REFCOUNT`, `SCAN`, `RANDOMKEY`, `TOUCH`, `DUMP`, `RESTORE`

**Valkey additions**: `DELIFEQ key expected_value` (conditional delete - only if value matches)

## Expiration
`EXPIRE`, `PEXPIRE`, `EXPIREAT`, `PEXPIREAT`, `TTL`, `PTTL`, `EXPIRETIME`, `PEXPIRETIME`, `PERSIST`
