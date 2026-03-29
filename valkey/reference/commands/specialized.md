# Specialized Data Types

Use HyperLogLog for approximate unique counting, bitmaps for compact boolean flags, and geospatial indexes for location-based queries. These types are built on top of Valkey's core string and sorted set types, providing specialized operations.

---

## HyperLogLog

HyperLogLog provides probabilistic cardinality estimation - counting unique elements with ~0.81% standard error using only 12 KB of memory regardless of the number of elements. Use when exact counts are not required but memory efficiency matters (e.g., unique visitors, distinct events).

### PFADD

```
PFADD key element [element ...]
```

Adds elements to the HyperLogLog. Returns 1 if the internal representation was modified, 0 otherwise.

**Complexity**: O(1) per element

```
PFADD visitors:2024-03-29 "user:100" "user:200" "user:300"
-- 1

PFADD visitors:2024-03-29 "user:100"    -- duplicate
-- 0 (no change to internal state)
```

### PFCOUNT

```
PFCOUNT key [key ...]
```

Returns the approximate cardinality. With multiple keys, returns the cardinality of the union (without modifying any key).

**Complexity**: O(1) for single key, O(N) for merge

```
PFCOUNT visitors:2024-03-29
-- 3

-- Union count across multiple days
PFCOUNT visitors:2024-03-28 visitors:2024-03-29
-- (approximate unique visitors across both days)
```

### PFMERGE

```
PFMERGE destkey sourcekey [sourcekey ...]
```

Merges multiple HyperLogLogs into `destkey`. The result approximates the cardinality of the union of all source sets.

**Complexity**: O(N) to merge N keys

```
-- Weekly unique visitors from daily HLLs
PFMERGE visitors:week:13 visitors:2024-03-25 visitors:2024-03-26 visitors:2024-03-27 visitors:2024-03-28 visitors:2024-03-29
PFCOUNT visitors:week:13
```

**Performance note**: Valkey 8.1+ uses AVX/AVX2 SIMD instructions for PFMERGE and PFCOUNT, achieving up to 12x faster execution.

---

## Bitmaps

Bitmaps are not a separate data type - they are string values operated on at the bit level. Each bit represents a boolean flag. Use for feature flags, daily active users, presence tracking, or any scenario with binary states across a large population.

### SETBIT

```
SETBIT key offset value
```

Sets or clears the bit at `offset`. Value must be 0 or 1. Returns the old bit value. The string is auto-extended if offset exceeds the current length.

**Complexity**: O(1)

```
-- Track user logins by day (user ID as offset)
SETBIT logins:2024-03-29 1000 1    -- user 1000 logged in
SETBIT logins:2024-03-29 2000 1    -- user 2000 logged in
-- 0 (previous value)
```

### GETBIT

```
GETBIT key offset
```

Returns the bit value at `offset`. Returns 0 if the offset is beyond the string length.

**Complexity**: O(1)

```
GETBIT logins:2024-03-29 1000    -- 1 (logged in)
GETBIT logins:2024-03-29 9999    -- 0 (did not log in)
```

### BITCOUNT

```
BITCOUNT key [start end [BYTE | BIT]]
```

Counts the number of bits set to 1. Without range, counts the entire string. With range, counts within byte or bit offsets (BIT mode since 7.0).

**Complexity**: O(N)

```
-- Total users who logged in today
BITCOUNT logins:2024-03-29
-- 2

-- Count bits in byte range
BITCOUNT logins:2024-03-29 0 10 BYTE

-- Count bits in bit range (7.0+)
BITCOUNT logins:2024-03-29 0 1023 BIT
```

**Performance note**: Valkey 8.1+ uses AVX2 SIMD for BITCOUNT, achieving up to 514% faster execution.

### BITOP

```
BITOP AND | OR | XOR | NOT destkey key [key ...]
```

Performs bitwise operations between strings and stores the result. NOT operates on a single key.

**Complexity**: O(N) where N is the longest string length

```
-- Users active on BOTH Monday and Tuesday
BITOP AND active:both logins:monday logins:tuesday

-- Users active on EITHER day
BITOP OR active:either logins:monday logins:tuesday

-- Count the intersection
BITCOUNT active:both
```

### BITPOS

```
BITPOS key bit [start [end [BYTE | BIT]]]
```

Returns the position of the first bit set to `bit` (0 or 1). Optionally search within a byte or bit range.

**Complexity**: O(N)

```
-- Find first user who logged in
BITPOS logins:2024-03-29 1
-- 1000

-- Find first user who did NOT log in (first 0 bit)
BITPOS logins:2024-03-29 0
```

### BITFIELD

```
BITFIELD key [GET encoding offset] [SET encoding offset value] [INCRBY encoding offset increment] [OVERFLOW WRAP | SAT | FAIL]
```

Treats the string as an array of arbitrary-width integers. Supports signed (i) and unsigned (u) encodings up to 64 bits. Multiple operations in a single command.

**Complexity**: O(1) per sub-command

```
-- Store 8-bit counters packed in a string
BITFIELD counters SET u8 0 100     -- set counter 0 to 100
BITFIELD counters SET u8 8 200     -- set counter 1 to 200
BITFIELD counters GET u8 0         -- 100
BITFIELD counters INCRBY u8 0 10   -- 110

-- Overflow control
BITFIELD counters OVERFLOW SAT INCRBY u8 0 200
-- Saturates at 255 instead of wrapping
```

**Encoding format**: `u8` = unsigned 8-bit, `i16` = signed 16-bit. Offsets are in bits. Prefix offset with `#` for type-width multiples: `#0` = offset 0, `#1` = offset 8 (for u8).

---

## Geospatial

Geospatial indexes are stored as sorted sets internally, using the Geohash as the score. Use for location-based queries - finding nearby places, distance calculations, or area searches.

### GEOADD

```
GEOADD key [NX | XX] [CH] longitude latitude member [longitude latitude member ...]
```

Adds members with longitude/latitude coordinates. Same NX/XX/CH options as ZADD. Valid longitude: -180 to 180. Valid latitude: -85.05 to 85.05.

**Complexity**: O(log N) per member

```
GEOADD locations -122.4194 37.7749 "san-francisco"
GEOADD locations -118.2437 34.0522 "los-angeles"
GEOADD locations -73.9857 40.7484 "new-york"
-- 3
```

### GEODIST

```
GEODIST key member1 member2 [M | KM | FT | MI]
```

Returns the distance between two members. Default unit is meters.

**Complexity**: O(1)

```
GEODIST locations "san-francisco" "los-angeles" km
-- "559.1133"

GEODIST locations "san-francisco" "new-york" mi
-- "2565.5538"
```

### GEOPOS

```
GEOPOS key member [member ...]
```

Returns the longitude/latitude of members. Returns nil for non-existent members.

**Complexity**: O(N)

```
GEOPOS locations "san-francisco" "missing"
-- 1) 1) "-122.41940..."
--    2) "37.77490..."
-- 2) (nil)
```

### GEOHASH

```
GEOHASH key member [member ...]
```

Returns the Geohash string representation of member positions. Useful for linking to external geohash-based systems.

**Complexity**: O(N)

```
GEOHASH locations "san-francisco"
-- 1) "9q8yyk8yuq0"
```

### GEOSEARCH

```
GEOSEARCH key
    FROMMEMBER member | FROMLONLAT longitude latitude
    BYRADIUS radius M | KM | FT | MI |
    BYBOX width height M | KM | FT | MI |
    BYPOLYGON num-vertices lon1 lat1 [lon lat ...]
    [ASC | DESC]
    [COUNT count [ANY]]
    [WITHCOORD] [WITHDIST] [WITHHASH]
```

Searches for members within a specified area. Three shape options: circle (BYRADIUS), rectangle (BYBOX), and polygon (BYPOLYGON, Valkey 9.0+).

**Complexity**: O(N+log M)

```
-- Find locations within 600km of San Francisco
GEOSEARCH locations FROMLONLAT -122.4194 37.7749 BYRADIUS 600 km ASC WITHCOORD WITHDIST
-- 1) 1) "san-francisco"
--    2) "0.0000"
--    3) 1) "-122.41940..." 2) "37.77490..."
-- 2) 1) "los-angeles"
--    2) "559.1133"
--    3) 1) "-118.24370..." 2) "34.05220..."

-- Search within a bounding box
GEOSEARCH locations FROMLONLAT -100 40 BYBOX 5000 3000 km ASC

-- Polygon search (Valkey 9.0+)
GEOSEARCH locations BYPOLYGON 4 -123 38 -117 38 -117 34 -123 34 ASC WITHCOORD
```

**FROMMEMBER vs FROMLONLAT**: Use FROMMEMBER to search relative to an existing member's position. Use FROMLONLAT to search from arbitrary coordinates.

**COUNT with ANY**: `COUNT 10` returns the 10 closest. `COUNT 10 ANY` returns any 10 within the area (faster, unordered).

### GEOSEARCHSTORE

```
GEOSEARCHSTORE destination source
    FROMMEMBER member | FROMLONLAT longitude latitude
    BYRADIUS radius M | KM | FT | MI |
    BYBOX width height M | KM | FT | MI |
    BYPOLYGON num-vertices lon1 lat1 [lon lat ...]
    [ASC | DESC]
    [COUNT count [ANY]]
    [STOREDIST]
```

Same as GEOSEARCH but stores results in `destination` as a sorted set. With STOREDIST, stores distances as scores instead of geohashes. Returns the number of members stored.

```
GEOSEARCHSTORE nearby:sf locations FROMLONLAT -122.4194 37.7749 BYRADIUS 100 km ASC COUNT 10
-- 1
```

---

## Practical Patterns

**Unique visitor counting (HyperLogLog)**:
```
-- Daily HLLs
PFADD visitors:2024-03-29 "session:abc" "session:def"
PFCOUNT visitors:2024-03-29    -- approximate count

-- Weekly aggregate
PFMERGE visitors:week:13 visitors:2024-03-25 visitors:2024-03-26 visitors:2024-03-27
PFCOUNT visitors:week:13
```

**Feature rollout tracking (bitmap)**:
```
-- Mark feature as enabled for user IDs
SETBIT feature:dark-mode 1000 1
SETBIT feature:dark-mode 2000 1

-- Check if user has feature
GETBIT feature:dark-mode 1000    -- 1

-- Count users with feature
BITCOUNT feature:dark-mode

-- Users with BOTH features (bitmap intersection)
BITOP AND both:features feature:dark-mode feature:beta-ui
```

**Daily active users (bitmap)**:
```
SETBIT dau:2024-03-29 user_id 1
BITCOUNT dau:2024-03-29           -- daily active count
BITOP OR wau dau:2024-03-23 dau:2024-03-24 dau:2024-03-25 dau:2024-03-26 dau:2024-03-27 dau:2024-03-28 dau:2024-03-29
BITCOUNT wau                       -- weekly active count
```

**Store locator (geospatial)**:
```
GEOADD stores -122.4194 37.7749 "store:sf-downtown"
GEOADD stores -122.4094 37.7849 "store:sf-north"

-- Find stores within 5km of user's location
GEOSEARCH stores FROMLONLAT -122.42 37.78 BYRADIUS 5 km ASC WITHDIST COUNT 5
```

**Delivery zone check (polygon, Valkey 9.0+)**:
```
-- Define delivery area as polygon coordinates
GEOADD restaurants -122.42 37.78 "pizza-place"
GEOSEARCH restaurants BYPOLYGON 4 -122.45 37.80 -122.38 37.80 -122.38 37.75 -122.45 37.75 ASC
-- Returns restaurants inside the delivery polygon
```

**Compact integer counters (BITFIELD)**:
```
-- Pack 1000 16-bit counters into a single key (~2KB)
BITFIELD counters SET u16 #0 0     -- counter 0
BITFIELD counters SET u16 #1 0     -- counter 1
BITFIELD counters INCRBY u16 #42 1 -- increment counter 42
BITFIELD counters GET u16 #42      -- read counter 42
```

---

## See Also

- [Geospatial Polygon Queries](../valkey-features/geospatial.md) - BYPOLYGON support (Valkey 9.0+)
- [Memory Best Practices](../best-practices/memory.md) - bitmaps for boolean flags, HyperLogLog for unique counting
- [Performance Summary](../valkey-features/performance-summary.md) - BITCOUNT and PFMERGE SIMD optimizations
