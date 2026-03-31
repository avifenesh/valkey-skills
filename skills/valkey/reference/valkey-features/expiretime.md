# EXPIRETIME and TTL Inspection Commands

Use when you need to check, manage, or audit key expiration. EXPIRETIME returns absolute Unix timestamps (useful for cross-service coordination), while TTL/PTTL return relative remaining time.

---

## Key TTL Inspection Commands

| Command | Returns | Since |
|---------|---------|-------|
| `TTL key` | Remaining seconds (-1 = no TTL, -2 = key missing) | 1.0 |
| `PTTL key` | Remaining milliseconds | 2.6 |
| `EXPIRETIME key` | Absolute Unix timestamp (seconds) when key expires | 7.0 |
| `PEXPIRETIME key` | Absolute Unix timestamp (milliseconds) | 7.0 |

## Why EXPIRETIME Matters

TTL/PTTL returns relative time - if you read TTL=300 and pass it to another service, by the time that service uses it, the actual remaining time is less. EXPIRETIME returns the absolute timestamp, which is unambiguous across services.

```
SET session:abc "data" EX 1800

# Relative - decays over time
TTL session:abc
# (integer) 1798

# Absolute - same answer regardless of when you read it
EXPIRETIME session:abc
# (integer) 1743456000  (Unix timestamp)
```

## Use Cases

**Session management - check if session is still valid without GET:**
```
# Check expiration without touching the key
EXPIRETIME session:user:1000
# Compare against current time to decide if refresh needed
```

**Coordinated cache invalidation across services:**
```
# Service A sets cache with TTL
SET cache:product:123 '{"name":"Widget"}' EX 3600

# Service B reads the absolute expiration for its own scheduling
PEXPIRETIME cache:product:123
# Use this timestamp to schedule a pre-fetch before expiry
```

**Audit keys for missing TTL:**
```
# Scan keys and check which ones have no expiration
SCAN 0 MATCH user:* COUNT 100
# For each key:
TTL user:1000
# -1 means no TTL set - potential memory leak
```

## PERSIST - Remove TTL

```
PERSIST key
```

Removes the TTL from a key, making it persistent. Returns 1 if TTL was removed, 0 if key had no TTL or doesn't exist.

```
SET temp:data "value" EX 60
PERSIST temp:data          # Returns 1, key no longer expires
TTL temp:data              # Returns -1 (no TTL)
```

**Use when**: a temporary key needs to become permanent (e.g., trial user becomes paying user, temp data becomes permanent record).

## Related: Hash Field TTL Inspection

For per-field expiration on hashes, see [hash-field-ttl](hash-field-ttl.md):
- `HTTL` / `HPTTL` - remaining time per field
- `HEXPIRETIME` / `HPEXPIRETIME` - absolute expiration per field
- `HPERSIST` - remove TTL from hash fields
