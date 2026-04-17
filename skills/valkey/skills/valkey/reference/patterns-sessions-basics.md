# Session Storage Basics

Use when implementing basic session storage in Valkey using hashes, or deciding between the classic approach and the Valkey 9.0+ per-field expiry approach.

## Classic Hash Sessions

Store each session as a hash key with an `EXPIRE` on the whole key:

```
HSET session:abc123 user_id 1000 role admin ip "192.168.1.1"
EXPIRE session:abc123 1800

# Read
HGETALL session:abc123

# Sliding timeout: reset TTL on each authenticated request
EXPIRE session:abc123 1800

# Rotate on privilege escalation (prevents session fixation)
# 1. HGETALL old key
# 2. HSET new key + EXPIRE
# 3. UNLINK old key
# Use MULTI/EXEC or a Lua script for atomicity on steps 2-3 - pipelining
# alone does not prevent another client from seeing the intermediate state
# (both keys present, or neither, depending on ordering). In cluster mode,
# co-locate old and new keys on the same slot via a hash tag,
# e.g. session:{user:1000}:abc123 and session:{user:1000}:xyz789.
```

This approach works and is well understood, but expiry is all-or-nothing on the whole key.

## Valkey 9.0+ Approach

For granular control - expire individual fields (tokens, temporary claims) independently of the session itself - use per-field TTL commands.

See `patterns-sessions-field-expiry.md` for `HSETEX`, `HGETEX`, `HEXPIRE`, and complete patterns.
