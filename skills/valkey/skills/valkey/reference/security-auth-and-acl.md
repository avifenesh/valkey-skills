# Authentication and ACL for Application Developers

Use when connecting your application to Valkey with authentication, configuring ACL permissions for your app user, or setting up TLS connections.

## Contents

- Authentication
- ACL Basics for Application Developers
- TLS Connection Setup
- Security Checklist for Application Developers

---

## Authentication

### Basic Password Authentication

Default user with a password:

```
# In valkey.conf (operator sets this)
requirepass your_strong_password
```

```
# Application connects and authenticates
AUTH your_strong_password
```

With a client library:

```javascript
// ioredis
const client = new Redis({
  host: 'valkey.example.com',
  port: 6379,
  password: 'your_strong_password',
});
```

```python
# redis-py / valkey-py
r = redis.Redis(
    host='valkey.example.com',
    port=6379,
    password='your_strong_password',
)
```

### Username + Password Authentication (ACL)

Named users with ACL for fine-grained access control:

```
# Authenticate with username and password
AUTH username password
```

```javascript
// ioredis with username
const client = new Redis({
  host: 'valkey.example.com',
  port: 6379,
  username: 'appuser',
  password: 'app_password',
});
```

```python
# redis-py with username
r = redis.Redis(
    host='valkey.example.com',
    port=6379,
    username='appuser',
    password='app_password',
)
```

---

## ACL Basics for Application Developers

ACLs are configured by the ops team. Application developers need to understand what permissions to request.

### What ACL Controls

| Scope | Example | Meaning |
|-------|---------|---------|
| Commands | `+@read +@write` | Which commands the user can run |
| Keys | `~app:*`, `allkeys`, `resetkeys` | Which key patterns the user can access |
| Read/write-scoped keys | `%R~read:*`, `%W~write:*` | Restrict a pattern to read-only or write-only access |
| Channels | `&notifications:*`, `allchannels`, `resetchannels` | Which pub/sub channels the user can use |
| Connection state | `on`/`off`, `>password`, `nopass` | Enable/disable the user and manage credentials |

ACLs do **not** restrict by database number - a user with `@write` on `~*` can write in any numbered database the server has. Use separate instances (or separate cluster deployments in 9.0+ cluster multi-db) for database-level isolation.

### Common Application Permission Patterns

**Read-write application** (most common):

```
ACL SETUSER appuser on >password ~app:* +@read +@write +@connection -@admin
```

Read/write keys matching `app:*`, manage own connection, no admin commands.

**Read-only replica reader**:

```
ACL SETUSER reader on >password ~* +@read +@connection
```

Read any key, no write access.

**Cache-only user** (limited to cache namespace):

```
ACL SETUSER cacheuser on >password ~cache:* +GET +SET +DEL +UNLINK +EXPIRE +TTL +@connection
```

Cache keys only, specific command set.

**Queue worker** (streams and lists):

```
ACL SETUSER worker on >password ~queue:* +XREADGROUP +XACK +XADD +BLPOP +RPUSH +@connection
```

### What Permissions to Request from Your Ops Team

Specify:

1. **Key patterns** your application accesses (e.g., `app:*`, `cache:*`, `session:*`)
2. **Command categories** needed (e.g., `@read`, `@write`, `@string`, `@hash`)
3. **Specific dangerous commands** you need, if any (e.g., `FLUSHDB` - usually not)
4. **Pub/sub channels** if your application uses pub/sub
5. **Read-only vs read-write** access per pattern if you need tighter isolation within the same user (`%R~` / `%W~`)

### Command Categories Reference

| Category | What It Includes |
|----------|-----------------|
| `@read` | Commands that read data (GET, HGET, LRANGE, etc.) |
| `@write` | Commands that modify data (SET, HSET, LPUSH, DEL, etc.) |
| `@string` | String type commands |
| `@hash` | Hash type commands |
| `@list` | List type commands |
| `@set` | Set type commands |
| `@sortedset` | Sorted set commands |
| `@stream` | Stream commands (XADD, XREAD, XREADGROUP, etc.) |
| `@pubsub` | Pub/Sub commands |
| `@connection` | Connection management (AUTH, SELECT, PING, CLIENT) |
| `@admin` | Administrative commands (CONFIG, SAVE, SHUTDOWN, etc.) |
| `@dangerous` | Potentially destructive commands (FLUSHALL, KEYS, DEBUG) |
| `@scripting` | Lua scripting and Functions |

View all categories at runtime: `ACL CAT` (see [Server Commands](basics-server-and-scripting.md) for ACL introspection)

---

## TLS Connection Setup

TLS encrypts data in transit. The ops team configures TLS on the server; configure it in the client.

### Basic TLS (Encryption Only)

```javascript
// ioredis
const client = new Redis({
  host: 'valkey.example.com',
  port: 6380,        // TLS port (operator-configured)
  tls: {
    ca: fs.readFileSync('/path/to/ca.crt'),
  },
});
```

```python
# redis-py / valkey-py
r = redis.Redis(
    host='valkey.example.com',
    port=6380,
    ssl=True,
    ssl_ca_certs='/path/to/ca.crt',
)
```

```java
// Jedis with TLS
JedisPool pool = new JedisPool(
    new JedisPoolConfig(),
    "valkey.example.com",
    6380,
    true   // useSsl
);
```

### Mutual TLS (mTLS)

When the server requires client certificates:

```javascript
// ioredis with mTLS
const client = new Redis({
  host: 'valkey.example.com',
  port: 6380,
  tls: {
    ca: fs.readFileSync('/path/to/ca.crt'),
    cert: fs.readFileSync('/path/to/client.crt'),
    key: fs.readFileSync('/path/to/client.key'),
  },
});
```

```python
# redis-py with mTLS
r = redis.Redis(
    host='valkey.example.com',
    port=6380,
    ssl=True,
    ssl_ca_certs='/path/to/ca.crt',
    ssl_certfile='/path/to/client.crt',
    ssl_keyfile='/path/to/client.key',
)
```

### TLS Performance Notes

- Valkey 8.1+ offloads TLS handshakes to I/O threads, so handshake cost no longer monopolizes the main thread under connection storms. Tune `io-threads` if TLS-heavy workloads are connection-bound.
- Once the TLS session is established, per-command overhead is minimal.
- For internal networks where encryption is handled at the network layer, plaintext connections are fine.

---

## Security Checklist for Application Developers

| Check | Detail |
|-------|--------|
| Use authentication | Never connect without `AUTH` - even in internal networks |
| Request minimum permissions | Only the commands and key patterns your app needs |
| Use TLS in production | Encrypt data in transit, especially across network boundaries |
| Do not embed credentials in code | Use environment variables or secrets management |
| Rotate passwords regularly | Coordinate with ops for password rotation |
| Do not use the default user in production | Create a named ACL user for each application |
| Avoid `@admin` and `@dangerous` | Your application should not need FLUSHALL, KEYS, or CONFIG (see [Anti-Patterns](anti-patterns-quick-reference.md)) |
| Separate pub/sub connections | Subscriber connections are monopolized - use separate auth if needed (see [Pub/Sub Commands](basics-data-types.md)) |

---

