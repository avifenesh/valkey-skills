# Session Storage Basics

Use when storing user sessions in Valkey with hashes, implementing sliding session timeouts, or rotating session IDs for security.

## Contents

- Basic Session Storage with Hashes (line 13)
- Sliding Session Timeout (line 93)
- Session Rotation (line 126)

---

## Basic Session Storage with Hashes

Each session is a hash key with fields for user data, metadata, and tokens.

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

Reset the TTL on every request. Active sessions stay alive, idle ones expire.

```
# On every authenticated request:
EXPIRE session:abc123 1800    # Reset to 30 minutes

# Or combine read + TTL refresh in one round-trip:
HGETALL session:abc123
EXPIRE session:abc123 1800
# Pipeline these two commands for efficiency
```

### Absolute Expiration with Sliding Idle

For both an absolute maximum lifetime and a sliding idle timeout, store the absolute deadline as a field:

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
