# EXPIRETIME and TTL Inspection

Use when inspecting key expiration, coordinating TTLs across services, or auditing keys for missing expiration.

## Commands

| Command | Success reply | `-1` | `-2` |
|---------|---------------|------|------|
| `TTL key` | Remaining seconds (integer) | Key exists, no TTL | Key missing |
| `PTTL key` | Remaining milliseconds | Key exists, no TTL | Key missing |
| `EXPIRETIME key` | Absolute Unix timestamp in seconds | Key exists, no TTL | Key missing |
| `PEXPIRETIME key` | Absolute Unix timestamp in milliseconds | Key exists, no TTL | Key missing |

| Command | Reply |
|---------|-------|
| `PERSIST key` | `1` if a TTL was removed; `0` **either** when the key has no TTL **or** when the key does not exist. Use `EXISTS` separately if you need to distinguish those. |

`EXPIRETIME`/`PEXPIRETIME` were added in Redis 7.0 and are available in all Valkey versions. Use the absolute form when passing expiration to another service - relative TTL decays in transit.

## Hash Field TTL

Valkey adds per-field expiration on hashes (not available in Redis). See [hash-field-ttl](valkey-features-hash-field-ttl.md) for `HEXPIRETIME`, `HTTL`, `HPERSIST`.
