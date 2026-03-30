# Hash Field Expiration

Use when you need per-field TTL on hash keys - session management with field-level expiry, cache entries that expire independently within a hash, or rate limiting with auto-expiring time windows.

Requires: Valkey 9.0+, GLIDE 2.1+.

Valkey 9.0 introduced per-field TTL on hash keys, allowing individual hash fields to expire independently.

## Supported Commands

All hash field expiration commands from the Rust core `request_type.rs`:

| Command | RequestType | Description |
|---------|-------------|-------------|
| HSETEX | `HSetEx` (617) | Set fields with optional expiration and conditions |
| HGETEX | `HGetEx` (618) | Get fields and optionally set/remove their expiration |
| HEXPIRE | `HExpire` (619) | Set field TTL in seconds |
| HEXPIREAT | `HExpireAt` (620) | Set field expiration as Unix timestamp (seconds) |
| HPEXPIRE | `HPExpire` (621) | Set field TTL in milliseconds |
| HPEXPIREAT | `HPExpireAt` (622) | Set field expiration as Unix timestamp (milliseconds) |
| HPERSIST | `HPersist` (623) | Remove expiration from fields |
| HTTL | `HTtl` (624) | Get remaining TTL in seconds |
| HPTTL | `HPTtl` (625) | Get remaining TTL in milliseconds |
| HEXPIRETIME | `HExpireTime` (626) | Get expiration Unix timestamp in seconds |
| HPEXPIRETIME | `HPExpireTime` (627) | Get expiration Unix timestamp in milliseconds |

**Requires**: Valkey 9.0+.

## GLIDE Version Support

GLIDE 2.1+ added hash field expiration across all languages (Go, Java, Node.js, Python).

## Option Types

### ExpirySet (for HSETEX)

Controls how expiration is applied when setting fields:

| ExpiryType | Wire Argument | Description |
|------------|---------------|-------------|
| `SEC` | `EX <seconds>` | Expire in N seconds |
| `MILLSEC` | `PX <milliseconds>` | Expire in N milliseconds |
| `UNIX_SEC` | `EXAT <timestamp>` | Expire at Unix timestamp (seconds) |
| `UNIX_MILLSEC` | `PXAT <timestamp>` | Expire at Unix timestamp (milliseconds) |
| `KEEP_TTL` | `KEEPTTL` | Retain existing TTL on the fields |

### ExpiryGetEx (for HGETEX)

Controls expiration changes when retrieving fields:

| ExpiryTypeGetEx | Wire Argument | Description |
|-----------------|---------------|-------------|
| `SEC` | `EX <seconds>` | Set expiry to N seconds |
| `MILLSEC` | `PX <milliseconds>` | Set expiry to N milliseconds |
| `UNIX_SEC` | `EXAT <timestamp>` | Set expiry to Unix timestamp (seconds) |
| `UNIX_MILLSEC` | `PXAT <timestamp>` | Set expiry to Unix timestamp (milliseconds) |
| `PERSIST` | `PERSIST` | Remove expiration from the fields |

### HashFieldConditionalChange (for HSETEX)

| Value | Wire Argument | Description |
|-------|---------------|-------------|
| `ONLY_IF_ALL_EXIST` | `FXX` | Only set fields if all already exist |
| `ONLY_IF_NONE_EXIST` | `FNX` | Only set fields if none already exist |

### ExpireOptions (for HEXPIRE, HPEXPIRE, HEXPIREAT, HPEXPIREAT)

| Value | Wire Argument | Description |
|-------|---------------|-------------|
| `HasNoExpiry` | `NX` | Set expiry only when the field has no expiry |
| `HasExistingExpiry` | `XX` | Set expiry only when the field already has an expiry |
| `NewExpiryGreaterThanCurrent` | `GT` | Set only when new expiry > current |
| `NewExpiryLessThanCurrent` | `LT` | Set only when new expiry < current |

## Return Value Codes

HEXPIRE, HPEXPIRE, HEXPIREAT, HPEXPIREAT return a list of status codes per field:

| Code | Meaning |
|------|---------|
| `1` | Expiration applied successfully |
| `0` | Condition not met (NX/XX/GT/LT check failed) |
| `-2` | Field or key does not exist |
| `2` | Field deleted immediately (TTL of 0 or timestamp in the past) |

HPERSIST returns:

| Code | Meaning |
|------|---------|
| `1` | Expiration removed (field is now persistent) |
| `-1` | Field exists but has no expiration |
| `-2` | Field or key does not exist |

HTTL, HPTTL return remaining time per field, or `-1` (no expiry), or `-2` (does not exist).

HEXPIRETIME, HPEXPIRETIME return the absolute expiration timestamp per field, or `-1` (no expiry), or `-2` (does not exist).

## Python Examples

### Set Fields with Expiration

```python
from glide import ExpirySet, ExpiryType, HashFieldConditionalChange

# Set fields with a 60-second TTL
result = await client.hsetex(
    "session:abc123",
    {"user_id": "42", "role": "admin", "last_page": "/dashboard"},
    expiry=ExpirySet(ExpiryType.SEC, 60),
)
# result: 1 (all fields set)

# Set only if fields don't already exist
result = await client.hsetex(
    "session:abc123",
    {"theme": "dark"},
    field_conditional_change=HashFieldConditionalChange.ONLY_IF_NONE_EXIST,
    expiry=ExpirySet(ExpiryType.SEC, 60),
)
# result: 1 (field was new)
```

### Get Fields and Modify Expiration

```python
from glide import ExpiryGetEx, ExpiryTypeGetEx

# Get values and extend TTL to 120 seconds
values = await client.hgetex(
    "session:abc123",
    ["user_id", "role"],
    expiry=ExpiryGetEx(ExpiryTypeGetEx.SEC, 120),
)
# values: [b"42", b"admin"]

# Get values and remove expiration (make persistent)
values = await client.hgetex(
    "session:abc123",
    ["user_id"],
    expiry=ExpiryGetEx(ExpiryTypeGetEx.PERSIST, None),
)
# values: [b"42"] - field no longer expires
```

### Set Expiration on Existing Fields

```python
from glide import ExpireOptions

# Set 30-second expiry on specific fields
codes = await client.hexpire("session:abc123", 30, ["last_page", "theme"])
# codes: [1, 1]

# Set expiry only if field has no existing expiry
codes = await client.hexpire(
    "session:abc123", 60, ["user_id"],
    option=ExpireOptions.HasNoExpiry,
)
# codes: [1] or [0] depending on current state

# Set expiry at a specific Unix timestamp
import time
future = int(time.time()) + 3600  # 1 hour from now
codes = await client.hexpireat("session:abc123", future, ["role"])
# codes: [1]

# Millisecond precision
codes = await client.hpexpire("session:abc123", 5000, ["last_page"])
# codes: [1] - expires in 5 seconds
```

### Query Expiration State

```python
# Get remaining TTL in seconds
ttls = await client.httl("session:abc123", ["user_id", "role", "missing"])
# ttls: [-1, 3542, -2]  (-1 = no expiry, -2 = doesn't exist)

# Get remaining TTL in milliseconds
ttls_ms = await client.hpttl("session:abc123", ["role"])
# ttls_ms: [3542000]

# Get absolute expiration timestamps
timestamps = await client.hexpiretime("session:abc123", ["role"])
# timestamps: [1711756800]

# Remove expiration
codes = await client.hpersist("session:abc123", ["role"])
# codes: [1] (expiration removed)
```

## Java Examples

```java
import glide.api.models.commands.HSetExOptions;
import glide.api.models.commands.HSetExOptions.ExpirySet;
import glide.api.models.commands.HGetExOptions;
import glide.api.models.commands.HGetExOptions.HGetExExpiry;

// Set fields with 60-second expiration
HSetExOptions options = HSetExOptions.builder()
    .expiry(ExpirySet.Seconds(60L))
    .build();
Long result = client.hsetex("session:abc123",
    Map.of("user_id", "42", "role", "admin"), options).get();
// result: 1

// Conditional: set only if none exist, with millisecond expiry
HSetExOptions condOptions = HSetExOptions.builder()
    .onlyIfNoneExist()
    .expiry(ExpirySet.Milliseconds(30000L))
    .build();
client.hsetex("session:abc123", Map.of("theme", "dark"), condOptions).get();

// Get values and set 120-second TTL
HGetExOptions getOptions = HGetExOptions.builder()
    .expiry(HGetExExpiry.Seconds(120L))
    .build();
String[] values = client.hgetex("session:abc123",
    new String[] {"user_id", "role"}, getOptions).get();

// Get values and remove expiration
HGetExOptions persistOptions = HGetExOptions.builder()
    .expiry(HGetExExpiry.Persist())
    .build();
String[] persistedValues = client.hgetex("session:abc123",
    new String[] {"user_id"}, persistOptions).get();
```

## Common Use Cases

**Session management with field-level TTL**: Store session data as hash fields with per-field expiration. Extend TTL on access with HGETEX. Sensitive fields (auth tokens) can expire faster than metadata fields.

**Cache entries within hashes**: Group related cache entries under one hash key. Each field expires independently - no need to invalidate the entire hash when one field goes stale.

**Rate limiting with field expiry**: Store rate limit counters as hash fields keyed by time window. Old windows expire automatically without manual cleanup.

**Partial data refresh**: Use GT/LT conditions with HEXPIRE to ensure TTLs only move in one direction. GT prevents accidentally shortening a TTL that was just refreshed by another process.

## Migration from Key-Level Expiry

Before Valkey 9.0, per-field expiry required separate string keys (e.g., `session:abc123:user_id`) each with their own EXPIRE. Hash field expiration consolidates these into a single hash key. Note that HSETEX returns `1`/`0` (success/condition-not-met) rather than the field count that HSET returns.

## Related Features

- [Batching](batching.md) - hash field expiration commands can be included in batches for pipelined or transactional usage
- [Scripting](scripting.md) - Lua scripts can call hash field expiration commands for atomic conditional workflows
