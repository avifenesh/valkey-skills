# Hash Field Expiration

Use when you need per-field TTL on hash entries - expiring individual fields without deleting the entire hash. Available in Valkey 9.0+.

## Contents

- Overview (line 21)
- New Commands (line 29)
- Core Operations (line 51)
- Return Values for TTL Commands (line 93)
- Use Case: Session Storage with Granular Expiration (line 105)
- Use Case: Feature Flags with Per-Flag Expiration (line 126)
- Use Case: Caching with Per-Field Freshness (line 142)
- Memory Overhead (line 155)
- Interaction with Key-Level TTL (line 163)
- Important Notes (line 172)
- See Also (line 182)

---

## Overview

Before hash field expiration, the only option for TTL was at the key level. If you had a user hash with `auth_token`, `csrf_token`, and `profile_data`, all fields shared the same lifetime. To expire fields independently, you had to split them into separate keys - losing the organizational benefit of hashes.

Valkey 9.0 adds per-field TTL. Each hash field can have its own expiration time, independent of the key-level TTL.

---

## New Commands

11 new commands for hash field expiration:

| Command | Purpose |
|---------|---------|
| `HEXPIRE key seconds FIELDS n field [field ...]` | Set TTL (seconds) on existing fields |
| `HEXPIREAT key unix-timestamp FIELDS n field [field ...]` | Set expiration at absolute Unix time |
| `HPEXPIRE key milliseconds FIELDS n field [field ...]` | Set TTL (milliseconds) on existing fields |
| `HPEXPIREAT key unix-ms-timestamp FIELDS n field [field ...]` | Set expiration at absolute Unix time (ms) |
| `HTTL key FIELDS n field [field ...]` | Get remaining TTL (seconds) per field |
| `HPTTL key FIELDS n field [field ...]` | Get remaining TTL (milliseconds) per field |
| `HEXPIRETIME key FIELDS n field [field ...]` | Get absolute expiration time per field |
| `HPEXPIRETIME key FIELDS n field [field ...]` | Get absolute expiration time (ms) per field |
| `HPERSIST key FIELDS n field [field ...]` | Remove TTL from fields (make persistent) |
| `HSETEX key [NX \| XX] [FNX \| FXX] [EX s \| PX ms \| EXAT t \| PXAT t \| KEEPTTL] FIELDS n field value [field value ...]` | Set fields with TTL and optional conditions in one command |
| `HGETEX key [EX s \| PX ms \| EXAT t \| PXAT t \| PERSIST] FIELDS n field [field ...]` | Get fields and set/refresh/remove TTL |

The `FIELDS n` argument specifies the count of field names that follow.

---

## Core Operations

### Set fields with TTL

```
# Set two fields with a 1-hour TTL
HSETEX user:1000 EX 3600 FIELDS 2 auth_token "tok_abc" csrf_token "csrf_xyz"
```

### Add TTL to existing fields

```
# Set 5-minute TTL on the CSRF token field
HEXPIRE user:1000 300 FIELDS 1 csrf_token
```

### Get fields and refresh TTL

```
# Read the auth token and reset its TTL to 1 hour
HGETEX user:1000 EX 3600 FIELDS 1 auth_token
```

### Check remaining TTL

```
# How long until csrf_token expires?
HTTL user:1000 FIELDS 1 csrf_token
# Returns seconds remaining, or:
#   -1 if field has no TTL
#   -2 if field does not exist
```

### Remove TTL from a field

```
# Make a field persistent (no expiration)
HPERSIST user:1000 FIELDS 1 profile_data
```

---

## Return Values for TTL Commands

When querying multiple fields, the commands return an array with one value per field:

| Value | Meaning |
|-------|---------|
| Positive integer | Remaining TTL in seconds (or ms for HP* variants) |
| `-1` | Field exists but has no TTL |
| `-2` | Field does not exist |

---

## Use Case: Session Storage with Granular Expiration

Store a user session as a single hash, with different lifetimes for different data:

```
# Create session with base data (30-minute session TTL)
HSET session:abc123 user_id 1000 role admin ip "10.0.0.1"
EXPIRE session:abc123 1800

# Short-lived sensitive fields
HSETEX session:abc123 EX 300 FIELDS 1 csrf_token "xyz789"        # 5-minute CSRF token
HSETEX session:abc123 EX 60 FIELDS 1 2fa_challenge "challenge1"  # 1-minute 2FA challenge

# On activity, refresh auth token but not CSRF
HGETEX session:abc123 EX 1800 FIELDS 1 auth_token
```

The CSRF token and 2FA challenge expire independently without affecting the rest of the session.

---

## Use Case: Feature Flags with Per-Flag Expiration

```
# Set feature flags with different lifetimes
HSETEX features:app EX 86400 FIELDS 1 new_checkout "true"       # 24-hour flag
HSETEX features:app EX 3600 FIELDS 1 beta_search "true"         # 1-hour flag

# Permanent flags
HSET features:app dark_mode "true"

# Check a flag - returns nil after expiration
HGET features:app beta_search
```

---

## Use Case: Caching with Per-Field Freshness

```
# Cache multiple API responses in one hash with different TTLs
HSETEX cache:user:1000 EX 3600 FIELDS 1 profile '{"name":"Alice"}'
HSETEX cache:user:1000 EX 60 FIELDS 1 notifications '{"count":5}'
HSETEX cache:user:1000 EX 300 FIELDS 1 recommendations '[...]'

# Frequently-changing data expires sooner, stable data persists longer
```

---

## Memory Overhead

Per-field expiration adds 16-29 bytes of overhead per expiring field. Standard hash operations (HGET, HSET, HGETALL, etc.) show no measurable performance regression.

Fields without TTL incur no additional overhead - the cost only applies to fields that have an expiration set.

---

## Interaction with Key-Level TTL

- Key-level EXPIRE still works and applies to the entire hash
- When the key expires, all fields (including those with their own TTL) are removed
- Field TTL and key TTL are independent - whichever triggers first wins
- If you PERSIST the key, field TTLs are unaffected

---

## Important Notes

- Hash field expiration uses the same lazy + active expiration mechanisms as key-level TTL
- HGETALL returns only non-expired fields
- HSCAN skips expired fields
- Field expiration events are published via keyspace notifications (when enabled)
- The `n` in `FIELDS n` must match the number of field names provided

---

## See Also

- [What is Valkey](../overview/what-is-valkey.md) - overview and Valkey-only feature list
- [Compatibility and Migration](../overview/compatibility.md) - migrating from Redis to Valkey
- [Conditional Operations](conditional-ops.md) - SET IFEQ and DELIFEQ
- [Cluster Enhancements](cluster-enhancements.md) - numbered databases in cluster mode
- [Polygon Geospatial Queries](geospatial.md) - GEOSEARCH BYPOLYGON (also 9.0)
- [Performance Summary](performance-summary.md) - version-by-version throughput and latency gains
- [Hash Commands](../basics/data-types.md) - HEXPIRE, HSETEX, HGETEX, HGETDEL command details
- [String Commands](../basics/data-types.md) - GETEX for key-level read-and-refresh TTL (analogous to HGETEX)
- [Session Patterns](../patterns/sessions.md) - per-field TTL for session tokens
- [Caching Patterns](../patterns/caching.md) - per-field freshness for cached API responses
- [Memory Best Practices](../best-practices/memory.md) - hash field expiration memory overhead
- For expiration internals: see valkey-dev `reference/config/expiry.md`
