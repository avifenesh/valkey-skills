# Bitmaps and HyperLogLog

Use when you need compact boolean flags (feature toggles, daily active users), bit-level operations (bitwise AND/OR across keys), or probabilistic unique counting with constant 12 KB memory (visitor counts, cardinality estimation).

GLIDE supports the full Valkey bitmap and HyperLogLog APIs. Bitmaps operate on string values at the bit level, while HyperLogLog provides probabilistic cardinality estimation with constant memory. BIT index type for BITCOUNT/BITPOS requires Valkey 7.0+.

## Bitmap Commands

All bitmap commands from the Rust core `request_type.rs`:

| Command | RequestType | Description |
|---------|-------------|-------------|
| BITCOUNT | `BitCount` (101) | Count set bits in a string |
| BITFIELD | `BitField` (102) | Perform arbitrary bitfield operations |
| BITFIELD_RO | `BitFieldReadOnly` (103) | Read-only bitfield operations |
| BITOP | `BitOp` (104) | Perform bitwise operations between strings |
| BITPOS | `BitPos` (105) | Find first bit set to 0 or 1 |
| GETBIT | `GetBit` (106) | Get the bit value at an offset |
| SETBIT | `SetBit` (107) | Set the bit value at an offset |

## HyperLogLog Commands

| Command | RequestType | Description |
|---------|-------------|-------------|
| PFADD | `PfAdd` (701) | Add elements to a HyperLogLog |
| PFCOUNT | `PfCount` (702) | Estimate cardinality of one or more HyperLogLogs |
| PFMERGE | `PfMerge` (703) | Merge multiple HyperLogLogs into one |

## Bitmap Configuration Types

### OffsetOptions

Specifies a range for BITCOUNT and BITPOS. Zero-based indexes where negative values count from the end.

- `start` (int): Starting offset index
- `end` (Optional[int]): Ending offset index (optional since Valkey 8.0+ for BITCOUNT)
- `index_type` (Optional[BitmapIndexType]): `BYTE` or `BIT` (Valkey 7.0+). Defaults to BYTE.

### BitwiseOperation Enum

Operations for BITOP:

| Value | Description |
|-------|-------------|
| `AND` | Bitwise AND across all keys |
| `OR` | Bitwise OR across all keys |
| `XOR` | Bitwise XOR across all keys |
| `NOT` | Bitwise NOT (single key only) |

## BitField Subcommands

BITFIELD treats a string as an array of bits with typed fields. Four subcommands control reads, writes, increments, and overflow behavior.

### Encoding Types

- **SignedEncoding(n)**: Signed integer, up to 64 bits. Prefix `i` (e.g., `i8`, `i16`).
- **UnsignedEncoding(n)**: Unsigned integer, up to 63 bits. Prefix `u` (e.g., `u8`, `u16`).

### Offset Types

- **BitOffset(n)**: Absolute bit position (e.g., `BitOffset(0)` = first bit).
- **BitOffsetMultiplier(n)**: Offset multiplied by the encoding size. Prefix `#`. For example, with `u8` encoding, `BitOffsetMultiplier(1)` means bit position 8.

### Subcommand Classes

**BitFieldGet(encoding, offset)**: Read a value at the given encoding and offset. Works in both BITFIELD and BITFIELD_RO.

**BitFieldSet(encoding, offset, value)**: Write a value. Returns the old value. BITFIELD only.

**BitFieldIncrBy(encoding, offset, increment)**: Increment a value. Returns the new value. BITFIELD only.

**BitFieldOverflow(overflow_control)**: Set the overflow behavior for subsequent SET/INCRBY operations in the same BITFIELD call.

### BitOverflowControl Enum

| Value | Behavior |
|-------|----------|
| `WRAP` | Modulo wrap on overflow (default). For signed, wraps from max to min and vice versa. |
| `SAT` | Saturate at min/max value on overflow/underflow. |
| `FAIL` | Return None on overflow/underflow. |

## Basic Bitmap Operations (Python)

### Get and Set Individual Bits

```python
# Set bit at offset 7 (creates key if needed)
old_val = await client.setbit("user:1001:flags", 7, 1)
# old_val: 0 (previous value)

# Get bit at offset 7
val = await client.getbit("user:1001:flags", 7)
# val: 1
```

### Count Set Bits

```python
from glide import OffsetOptions, BitmapIndexType

# Count all set bits
count = await client.bitcount("user:1001:flags")
# count: 1

# Count bits in byte range [0, 1]
count = await client.bitcount("mykey", OffsetOptions(0, 1))

# Count bits in bit range [0, 7] (Valkey 7.0+)
count = await client.bitcount("mykey", OffsetOptions(0, 7, BitmapIndexType.BIT))
```

### Find First Set/Unset Bit

```python
from glide import OffsetOptions, BitmapIndexType

# Find first bit set to 1
pos = await client.bitpos("mykey", 1)

# Find first 0-bit in byte range [1, -1]
pos = await client.bitpos("mykey", 0, OffsetOptions(1, -1))

# Find first 1-bit in bit range [0, 15] (Valkey 7.0+)
pos = await client.bitpos("mykey", 1, OffsetOptions(0, 15, BitmapIndexType.BIT))
```

### Bitwise Operations

```python
from glide import BitwiseOperation

await client.set("key1", "A")  # binary: 01000001
await client.set("key2", "B")  # binary: 01000010

# AND: result = 01000000 = "@"
length = await client.bitop(BitwiseOperation.AND, "result", ["key1", "key2"])
# length: 1 (bytes in result)

# OR: result = 01000011 = "C"
await client.bitop(BitwiseOperation.OR, "result", ["key1", "key2"])

# NOT: single key only
await client.bitop(BitwiseOperation.NOT, "result", ["key1"])
```

**Cluster mode note**: BITOP requires `destination` and all `keys` to map to the same hash slot.

## BitField Operations (Python)

```python
from glide import (
    BitFieldGet, BitFieldSet, BitFieldIncrBy, BitFieldOverflow,
    UnsignedEncoding, SignedEncoding, BitOffset, BitOffsetMultiplier,
    BitOverflowControl,
)

# Read an unsigned 8-bit integer at bit offset 0
results = await client.bitfield("mykey", [
    BitFieldGet(UnsignedEncoding(8), BitOffset(0)),
])
# results: [65]  (if key contains "A" = 0x41)

# Set an unsigned 8-bit value and read it back
results = await client.bitfield("mykey", [
    BitFieldSet(UnsignedEncoding(8), BitOffset(0), 66),
    BitFieldGet(UnsignedEncoding(8), BitOffset(0)),
])
# results: [65, 66]  (old value, new value)

# Increment with overflow control
results = await client.bitfield("counter", [
    BitFieldOverflow(BitOverflowControl.SAT),
    BitFieldIncrBy(UnsignedEncoding(8), BitOffset(0), 200),
    BitFieldIncrBy(UnsignedEncoding(8), BitOffset(0), 200),
])
# results: [200, 255]  (saturated at max u8)

# Use offset multiplier for array-like access
results = await client.bitfield("scores", [
    BitFieldSet(UnsignedEncoding(8), BitOffsetMultiplier(0), 10),
    BitFieldSet(UnsignedEncoding(8), BitOffsetMultiplier(1), 20),
    BitFieldSet(UnsignedEncoding(8), BitOffsetMultiplier(2), 30),
])
# Stores three 8-bit values at byte positions 0, 1, 2

# Read-only variant (safe for replicas)
results = await client.bitfield_read_only("scores", [
    BitFieldGet(UnsignedEncoding(8), BitOffsetMultiplier(0)),
    BitFieldGet(UnsignedEncoding(8), BitOffsetMultiplier(1)),
])
# results: [10, 20]
```

## HyperLogLog Operations (Python)

```python
# Add elements
changed = await client.pfadd("visitors:2024-03-29", ["user:1", "user:2", "user:3"])
# changed: True (structure modified)

changed = await client.pfadd("visitors:2024-03-29", ["user:1"])
# changed: False (user:1 already counted)

# Estimate cardinality
count = await client.pfcount(["visitors:2024-03-29"])
# count: 3

# Merge multiple HyperLogLogs
await client.pfadd("visitors:2024-03-28", ["user:2", "user:4", "user:5"])
result = await client.pfmerge("visitors:week", ["visitors:2024-03-28", "visitors:2024-03-29"])
# result: OK

total = await client.pfcount(["visitors:week"])
# total: 5 (approximate unique visitors across both days)
```

**Cluster mode note**: PFCOUNT with multiple keys and PFMERGE require all keys to map to the same hash slot.

## Common Use Cases

**Feature flags with bitmaps**: Use SETBIT/GETBIT with a per-user key where each bit offset represents a feature. Bit 0 = dark mode, bit 1 = beta features, etc. Compact storage - 1 byte covers 8 flags.

**Daily active users**: Use one bitmap key per day (e.g., `dau:2024-03-29`). SETBIT at the user's numeric ID offset when they are active. BITCOUNT gives the daily total. BITOP AND across days gives users active every day.

**User activity tracking**: One bitmap per user per period. SETBIT at the day-of-year offset when the user logs in. BITCOUNT returns total active days. BITPOS finds the first/last active day.

**Unique visitor counts with HyperLogLog**: PFADD each visitor ID. PFCOUNT returns the approximate unique count using only 12 KB of memory regardless of cardinality. PFMERGE combines time periods. Standard error is 0.81%.

**Bloom-filter-like dedup**: Use BITFIELD to pack multiple small counters into a single key for counting-bloom-filter patterns. OVERFLOW SAT prevents counter wraparound.

**Compact integer arrays**: Use BITFIELD with offset multipliers to store arrays of fixed-width integers in a single key. Efficient for leaderboard scores, small counters, or packed sensor readings.

## Related Features

- [Batching](batching.md) - bitmap and HyperLogLog commands can be included in batches for pipelined or transactional usage
- [Scripting](scripting.md) - combine bitmap operations with Lua scripts for atomic read-modify-write patterns
