# Authentication and ACL for Application Developers

Use when connecting your application to Valkey with authentication, configuring ACL permissions for your app user, or setting up TLS connections.

---

## Authentication

### Basic Password Authentication

The simplest authentication uses the default user with a password:

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

For fine-grained access control, Valkey supports named users with the ACL system:

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

ACLs are typically configured by your ops team, but as an application developer you should understand what permissions your app user needs and how to request them.

### What ACL Controls

| Scope | Example | Meaning |
|-------|---------|---------|
| Commands | `+@read +@write` | Which commands the user can run |
| Keys | `~app:*` | Which key patterns the user can access |
| Channels | `&notifications:*` | Which pub/sub channels the user can use |
| Databases | `alldbs` or specific database restrictions | Which databases the user can SELECT |

### Common Application Permission Patterns

**Read-write application** (most common):

```
ACL SETUSER appuser on >password ~app:* +@read +@write +@connection -@admin
```

This user can read and write keys matching `app:*`, manage its own connection, but cannot run admin commands.

**Read-only replica reader**:

```
ACL SETUSER reader on >password ~* +@read +@connection
```

Can read any key but cannot write.

**Cache-only user** (limited to cache namespace):

```
ACL SETUSER cacheuser on >password ~cache:* +GET +SET +DEL +UNLINK +EXPIRE +TTL +@connection
```

Can only access cache keys with a specific set of commands.

**Queue worker** (streams and lists):

```
ACL SETUSER worker on >password ~queue:* +XREADGROUP +XACK +XADD +BLPOP +RPUSH +@connection
```

### What Permissions to Request from Your Ops Team

When requesting an ACL user, specify:

1. **Key patterns** your application accesses (e.g., `app:*`, `cache:*`, `session:*`)
2. **Command categories** needed (e.g., `@read`, `@write`, `@string`, `@hash`)
3. **Specific dangerous commands** you need, if any (e.g., `FLUSHDB` - usually not)
4. **Pub/sub channels** if your application uses pub/sub
5. **Database numbers** if using numbered databases (9.0+ cluster mode)

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

View all categories at runtime: `ACL CAT`

---

## TLS Connection Setup

TLS encrypts data in transit between your application and Valkey. Your ops team configures TLS on the server; you configure it in your client.

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

When the server requires client certificates for authentication:

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

- Valkey 8.1+ offloads TLS handshakes to I/O threads, reducing connection setup overhead by 300%
- Once the TLS session is established, per-command overhead is minimal
- For internal networks where encryption is handled at the network layer, plaintext connections are fine

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
| Avoid `@admin` and `@dangerous` | Your application should not need FLUSHALL, KEYS, or CONFIG |
| Separate pub/sub connections | Subscriber connections are monopolized - use separate auth if needed |

---

## See Also

- [Anti-Patterns](../anti-patterns/quick-reference.md) - security anti-patterns (no auth, FLUSHALL accessible)
- [Clients Overview](../clients/overview.md) - TLS configuration per client library
- [Cluster Enhancements](../valkey-features/cluster-enhancements.md) - numbered databases and ACL database restrictions
- For operational ACL and TLS setup: see valkey-ops `reference/security/acl.md` and `reference/security/tls.md`
