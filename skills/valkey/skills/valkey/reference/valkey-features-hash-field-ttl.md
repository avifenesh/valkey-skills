# Hash Field Expiration

Use when you need per-field TTL on hash entries - expiring individual fields without deleting the entire hash. Available in Valkey 9.0+.

## Overview

Before 9.0, TTL was key-level only. A user hash with `auth_token`, `csrf_token`, and `profile_data` shared the same lifetime. Expiring fields independently required separate keys, losing hash organization benefits.

Valkey 9.0 adds per-field TTL. Each hash field has its own expiration, independent of key-level TTL.

---

## New Commands

11 new commands for hash field expiration (all since 9.0.0):

### Setters (HEXPIRE family)

| Command | Syntax |
|---------|--------|
| `HEXPIRE` | `HEXPIRE key seconds [NX \| XX \| GT \| LT] FIELDS n field [field ...]` |
| `HEXPIREAT` | `HEXPIREAT key unix-timestamp [NX \| XX \| GT \| LT] FIELDS n field [field ...]` |
| `HPEXPIRE` | `HPEXPIRE key milliseconds [NX \| XX \| GT \| LT] FIELDS n field [field ...]` |
| `HPEXPIREAT` | `HPEXPIREAT key unix-ms-timestamp [NX \| XX \| GT \| LT] FIELDS n field [field ...]` |

Condition flags (`NX | XX | GT | LT`) are **per-field** and mutually exclusive:

- `NX` - set TTL only if the field has no existing TTL
- `XX` - set TTL only if the field already has a TTL
- `GT` - set TTL only if the new TTL is greater than the current one
- `LT` - set TTL only if the new TTL is less than the current one

### Inspection

| Command | Syntax |
|---------|--------|
| `HTTL` | `HTTL key FIELDS n field [field ...]` — remaining seconds per field |
| `HPTTL` | `HPTTL key FIELDS n field [field ...]` — remaining milliseconds per field |
| `HEXPIRETIME` | `HEXPIRETIME key FIELDS n field [field ...]` — absolute Unix seconds |
| `HPEXPIRETIME` | `HPEXPIRETIME key FIELDS n field [field ...]` — absolute Unix milliseconds |

### Clear TTL

| Command | Syntax |
|---------|--------|
| `HPERSIST` | `HPERSIST key FIELDS n field [field ...]` — remove TTL from fields |

### Combined set-and-expire, get-and-expire

| Command | Syntax |
|---------|--------|
| `HSETEX` | `HSETEX key [FNX \| FXX] [EX s \| PX ms \| EXAT t \| PXAT t \| KEEPTTL] FIELDS n field value [field value ...]` |
| `HGETEX` | `HGETEX key [EX s \| PX ms \| EXAT t \| PXAT t \| PERSIST] FIELDS n field [field ...]` |

`FNX` = set only if **none** of the named fields already exist; `FXX` = set only if **all** of the named fields already exist. Applies to the whole operation — if the condition fails, **nothing** is set (HSETEX is atomic all-or-nothing).

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

## Return Values

### HEXPIRE / HEXPIREAT / HPEXPIRE / HPEXPIREAT (setters)

Array of per-field result codes:

| Code | Meaning |
|------|---------|
| `1` | Expiration was applied |
| `2` | TTL was `0` (or absolute time in the past) - field was deleted immediately |
| `0` | `NX` / `XX` / `GT` / `LT` condition not met - no change |
| `-2` | Field does not exist (or the hash key does not exist) |

Common mistake: checking for `-1` on an HEXPIRE result. `-1` is an HTTL/HPTTL code, not a setter code. HEXPIRE never returns `-1`.

### HTTL / HPTTL / HEXPIRETIME / HPEXPIRETIME (inspection)

Array of per-field result codes:

| Code | Meaning |
|------|---------|
| Positive integer | Remaining TTL or absolute expiration (seconds or ms per command) |
| `-1` | Field exists but has no TTL |
| `-2` | Field does not exist |

### HPERSIST

Array of per-field result codes:

| Code | Meaning |
|------|---------|
| `1` | TTL was removed |
| `-1` | Field exists but had no TTL to remove |
| `-2` | Field does not exist |

### HSETEX

Scalar (atomic): `1` if all fields (and any conditions) succeeded, `0` if any `FNX`/`FXX` condition failed - in which case **nothing** was written.

### HGETEX

Array of values in field order: each element is the field's current string value, or `nil` if the field is missing or already expired. Same shape as `HMGET`.

---

## Use Case: Session Storage with Granular Expiration

Single hash per session, different lifetimes per field:

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

Only fields that carry a TTL pay the extra metadata cost; fields without TTL are stored exactly as before. Adding TTLs to a previously-non-volatile hash promotes it into a "volatile-capable" encoding - budget for a small per-field increase when you start using HEXPIRE heavily.

---

## Interaction with Key-Level TTL

- Key-level EXPIRE still works and applies to the entire hash
- When the key expires, all fields (including those with their own TTL) are removed
- Field TTL and key TTL are independent - whichever triggers first wins
- If you PERSIST the key, field TTLs are unaffected

---

## Important Notes

- Hash field expiration uses the same lazy + active expiration mechanisms as key-level TTL. A field expires when it's next accessed or when the active expiration cycle visits the hash, whichever comes first.
- `HGETALL`, `HSCAN`, `HKEYS`, `HVALS` skip fields that have already been expired by either mechanism. A field whose TTL has just passed but hasn't yet been evaluated may be returned once, then disappear. If strict freshness matters, follow up with `HTTL`/`HEXISTS`.
- Field expiration events are published via keyspace notifications (when enabled)
- The `n` in `FIELDS n` must match the number of field names provided - mismatch returns a syntax error.
- Setting TTL to `0` (or a past absolute timestamp) via `HEXPIRE` / `HEXPIREAT` / `HPEXPIRE` / `HPEXPIREAT` **deletes the field immediately** and returns `2`. This is a feature, not an edge case - `HEXPIRE key 0 FIELDS n f1 f2` is a conditional delete based on existence.

---

