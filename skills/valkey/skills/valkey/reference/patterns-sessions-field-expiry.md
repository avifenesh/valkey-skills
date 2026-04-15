# Session Field Expiry and Management

Use when leveraging Valkey 9.0+ per-field TTL for session data with mixed volatility, counting active sessions per user, or enforcing concurrent session limits.

## Hash Field Expiration (Valkey 9.0+)

Valkey 9.0 per-field TTL eliminates splitting session data across multiple keys for different expiration needs.

### Use Cases

- CSRF tokens that expire in 5 minutes while the session lasts 30 minutes
- OTP codes that expire in 60 seconds
- Temporary authorization grants with short lifespans
- Cached derived data within a session hash

### Commands

```
# Set fields with per-field TTL
HSETEX session:abc123 EX 300 FIELDS 2 csrf_token "tok_abc" otp_code "123456"
# csrf_token and otp_code expire in 5 minutes

# Set TTL on existing fields
HEXPIRE session:abc123 60 FIELDS 1 otp_code
# otp_code now expires in 60 seconds

# Get field and refresh its TTL
HGETEX session:abc123 EX 300 FIELDS 1 csrf_token
# Returns csrf_token value and resets its TTL to 5 minutes

# Check remaining TTL on a field
HTTL session:abc123 FIELDS 1 csrf_token
# Returns remaining seconds

# Remove TTL from a field (make it persistent within the hash)
HPERSIST session:abc123 FIELDS 1 user_id
```

### Code Example

**Node.js (with Valkey GLIDE or compatible client)**:
```javascript
class SessionStoreV9 {
  async create(sessionId, userData, tempData) {
    const key = `session:${sessionId}`;

    // Set persistent session fields with 30-min key TTL
    await this.redis.hset(key, userData);
    await this.redis.expire(key, 1800);

    // Set short-lived fields with per-field TTL
    if (tempData.csrf_token) {
      await this.redis.sendCommand([
        'HSETEX', key, 'EX', '300',
        'FIELDS', '1', 'csrf_token', tempData.csrf_token
      ]);
    }
  }

  async refreshCsrf(sessionId, newToken) {
    const key = `session:${sessionId}`;
    await this.redis.sendCommand([
      'HSETEX', key, 'EX', '300',
      'FIELDS', '1', 'csrf_token', newToken
    ]);
  }
}
```

### Sliding Window with HGETEX

HGETEX reads session fields and atomically refreshes their TTL in one command - a true per-field sliding window where each field's TTL resets on access.

```
# Read core session data and refresh TTL to 1 hour in one atomic call
HGETEX session:abc123 EX 3600 FIELDS 2 user_id email
-- 1) "42"
-- 2) "alice@example.com"
-- Both fields now have a fresh 1-hour TTL
```

Eliminates the two-command pipeline (HMGET + HEXPIRE). Each field's TTL is independent - accessing `user_id` does not refresh `csrf_token`.

### Session Data with Mixed Volatility

| Field | TTL | Rationale |
|-------|-----|-----------|
| user_id, email | Session lifetime (1h) | Core identity data |
| csrf_token | 5 minutes | Security token, short-lived |
| cart_data | 15 minutes | Stale quickly, expensive to maintain |
| last_activity | No expiry (PERSIST) | Analytics, updated on each access |
| oauth_token | Matches token expiry | Auto-cleanup with token |

### Gotchas for Per-Field TTL in Sessions

1. **HSET strips field TTL**: Plain HSET on a field with TTL removes the expiration. Always use HSETEX with KEEPTTL when updating volatile fields.
2. **Field-level EXPIRE is not key-level EXPIRE**: HEXPIRE sets TTL on fields, not on the key itself. Set a key-level EXPIRE as a safety net so the entire session is cleaned up eventually.
3. **Expired fields are cleaned up by periodic job**: Not instantly. Between logical expiry and physical deletion, HLEN may count expired fields.

### Memory Overhead

16-29 bytes per expiring field. No measurable performance regression. Negligible compared to splitting across multiple keys (~70-80 bytes metadata per key).

---

## Session Counting and Management

### Count Active Sessions per User

Use a set to track active session IDs per user:

```
# On session create
SADD user:1000:sessions session:abc123
EXPIRE user:1000:sessions 86400    # 24-hour cleanup

# Count active sessions
SCARD user:1000:sessions

# List all sessions
SMEMBERS user:1000:sessions

# On session destroy
SREM user:1000:sessions session:abc123
```

### Invalidate All User Sessions

```python
async def invalidate_all_sessions(user_id: int):
    sessions_key = f"user:{user_id}:sessions"
    session_ids = await redis.smembers(sessions_key)

    if session_ids:
        pipeline = redis.pipeline()
        for sid in session_ids:
            pipeline.unlink(sid)
        pipeline.unlink(sessions_key)
        await pipeline.execute()
```

### Maximum Concurrent Sessions

Limit users to N concurrent sessions:

```python
async def enforce_session_limit(user_id: int, max_sessions: int = 5):
    sessions_key = f"user:{user_id}:sessions"
    count = await redis.scard(sessions_key)

    if count >= max_sessions:
        # Remove oldest session (requires tracking creation time)
        # Or simply remove a random one
        oldest = await redis.spop(sessions_key)
        if oldest:
            await redis.unlink(oldest)
```

---

## Production Tips

- **Generate cryptographically random session IDs** - use 128+ bits of randomness
- **Never expose internal session structure** in API responses
- **Use `HMGET` instead of `HGETALL`** when you only need specific fields
- **Pipeline session read + TTL refresh** to save a round-trip
- **Set key-level TTL even with per-field expiration** as a safety net - the key TTL is the absolute upper bound

---
