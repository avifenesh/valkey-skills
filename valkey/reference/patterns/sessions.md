# Session Storage Patterns

Use when storing user sessions in Valkey, implementing session expiration, or leveraging hash field expiration for per-field TTL on session data.

---

## Basic Session Storage with Hashes

Hashes are the natural fit for sessions: each session is a hash key with fields for user data, metadata, and tokens.

### Create and Read Sessions

```
# Create session
HSET session:abc123 user_id 1000 role admin ip "192.168.1.1" created_at 1711670400
EXPIRE session:abc123 1800    # 30-minute session timeout

# Read full session
HGETALL session:abc123

# Read specific fields (more efficient than HGETALL)
HMGET session:abc123 user_id role
```

### Code Examples

**Node.js**:
```javascript
class SessionStore {
  constructor(redis, ttlSeconds = 1800) {
    this.redis = redis;
    this.ttl = ttlSeconds;
  }

  async create(sessionId, data) {
    const key = `session:${sessionId}`;
    await this.redis.hset(key, data);
    await this.redis.expire(key, this.ttl);
    return sessionId;
  }

  async get(sessionId) {
    const key = `session:${sessionId}`;
    const data = await this.redis.hgetall(key);
    if (!Object.keys(data).length) return null;
    return data;
  }

  async touch(sessionId) {
    // Reset TTL on activity (sliding session)
    return this.redis.expire(`session:${sessionId}`, this.ttl);
  }

  async destroy(sessionId) {
    return this.redis.unlink(`session:${sessionId}`);
  }
}
```

**Python**:
```python
class SessionStore:
    def __init__(self, redis, ttl_seconds=1800):
        self.redis = redis
        self.ttl = ttl_seconds

    async def create(self, session_id: str, data: dict) -> str:
        key = f"session:{session_id}"
        await self.redis.hset(key, mapping=data)
        await self.redis.expire(key, self.ttl)
        return session_id

    async def get(self, session_id: str) -> dict | None:
        key = f"session:{session_id}"
        data = await self.redis.hgetall(key)
        return data if data else None

    async def touch(self, session_id: str):
        await self.redis.expire(f"session:{session_id}", self.ttl)

    async def destroy(self, session_id: str):
        await self.redis.unlink(f"session:{session_id}")
```

---

## Sliding Session Timeout

Reset the TTL every time the user makes a request. This keeps active sessions alive while expiring idle ones.

```
# On every authenticated request:
EXPIRE session:abc123 1800    # Reset to 30 minutes

# Or combine read + TTL refresh in one round-trip:
HGETALL session:abc123
EXPIRE session:abc123 1800
# Pipeline these two commands for efficiency
```

### Absolute Expiration with Sliding Idle

Sometimes you want both: an absolute maximum session lifetime AND a sliding idle timeout. Store the absolute deadline as a field:

```
HSET session:abc123 user_id 1000 max_expires_at 1711756800
EXPIRE session:abc123 1800    # Sliding idle timeout

# On each request:
max_expires = HGET session:abc123 max_expires_at
if current_time > max_expires:
    UNLINK session:abc123    # Session expired absolutely
else:
    EXPIRE session:abc123 1800    # Refresh idle timeout
```

---

## Hash Field Expiration (Valkey 9.0+)

Valkey 9.0 introduced per-field TTL on hashes. This eliminates the need to split session data across multiple keys when different fields have different expiration needs.

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

Use HGETEX to read session fields and atomically refresh their TTL in one command. This implements a true per-field sliding window - each field's TTL resets on access.

```
# Read core session data and refresh TTL to 1 hour in one atomic call
HGETEX session:abc123 EX 3600 FIELDS 2 user_id email
-- 1) "42"
-- 2) "alice@example.com"
-- Both fields now have a fresh 1-hour TTL
```

This eliminates the two-command pipeline (HMGET + EXPIRE) for session access. Each field's TTL is managed independently - accessing `user_id` does not refresh `csrf_token`.

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

Per-field expiration adds 16-29 bytes per expiring field. No measurable performance regression on standard hash operations. The overhead is negligible compared to splitting data across multiple keys (each key has ~70-80 bytes of metadata).

---

## Session Rotation

Rotate session IDs on privilege escalation (login, role change) to prevent session fixation attacks.

```python
async def rotate_session(old_session_id: str) -> str:
    new_session_id = generate_session_id()
    old_key = f"session:{old_session_id}"
    new_key = f"session:{new_session_id}"

    # Copy session data to new key
    data = await redis.hgetall(old_key)
    if not data:
        raise SessionExpired()

    # Atomic: create new session and destroy old one
    pipeline = redis.pipeline()
    pipeline.hset(new_key, mapping=data)
    pipeline.expire(new_key, 1800)
    pipeline.unlink(old_key)
    await pipeline.execute()

    return new_session_id
```

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

## See Also

- [Hash Commands](../commands/hashes.md) - HSET, HMGET, HGETALL for session storage
- [Hash Field Expiration](../valkey-features/hash-field-ttl.md) - per-field TTL for session tokens (Valkey 9.0+)
- [Caching Patterns](caching.md) - cache-aside pattern for session-adjacent data
- [Lock Patterns](locks.md) - distributed locks for session-critical operations
- [Memory Best Practices](../best-practices/memory.md) - hash encoding thresholds for session data
- [Key Best Practices](../best-practices/keys.md) - key naming conventions
