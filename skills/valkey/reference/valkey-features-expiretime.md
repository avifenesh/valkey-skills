# EXPIRETIME and TTL Inspection

Use when inspecting key expiration, coordinating TTLs across services, or auditing keys for missing expiration.

## Commands

| Command | Returns |
|---------|---------|
| `TTL key` | Remaining seconds (-1 = no TTL, -2 = missing) |
| `PTTL key` | Remaining milliseconds |
| `EXPIRETIME key` | Absolute Unix timestamp (seconds) at expiry |
| `PEXPIRETIME key` | Absolute Unix timestamp (milliseconds) at expiry |
| `PERSIST key` | Remove TTL; returns 1 if removed, 0 if none |

`EXPIRETIME`/`PEXPIRETIME` were added in Redis 7.0 and are available in all Valkey versions. Use the absolute form when passing expiration to another service - relative TTL decays in transit.

## Hash Field TTL

Valkey adds per-field expiration on hashes (not available in Redis). See [hash-field-ttl](hash-field-ttl.md) for `HEXPIRETIME`, `HTTL`, `HPERSIST`.
