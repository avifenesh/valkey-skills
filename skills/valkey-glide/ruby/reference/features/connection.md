# Connection and Configuration (Ruby)

Use when creating a GLIDE Ruby client, choosing between standalone and cluster mode, configuring authentication, TLS, timeouts, reconnection, read strategy, or migrating from redis-rb.

## Contents

- Client Class (line 17)
- Standalone Connection (line 37)
- URL-Based Connection (line 63)
- Cluster Connection (line 71)
- Authentication (line 85)
- TLS/SSL (line 98)
- Reconnection (line 121)
- Other Options (line 133)
- redis-rb Compatibility (line 140)

## Client Class

The Ruby client uses a single `Valkey` class. Standalone and cluster modes are controlled by the `cluster_mode` option.

```ruby
require "valkey"

# Standalone (default)
client = Valkey.new(host: "localhost", port: 6379)

# Cluster mode
client = Valkey.new(
  nodes: [
    { host: "node1.example.com", port: 6379 },
    { host: "node2.example.com", port: 6380 },
  ],
  cluster_mode: true
)
```

## Standalone Connection

Minimal:

```ruby
client = Valkey.new
# Defaults to localhost:6379
```

With full configuration:

```ruby
client = Valkey.new(
  host: "localhost",
  port: 6379,
  password: "secret",
  username: "myuser",
  db: 0,
  ssl: true,
  timeout: 5.0,
  connect_timeout: 3.0,
  client_name: "my-app",
  protocol: :resp2,
)
```

## URL-Based Connection

```ruby
client = Valkey.new(url: "redis://user:pass@localhost:6379/0")
```

Supports `redis://` and `rediss://` (TLS) schemes, matching redis-rb conventions.

## Cluster Connection

```ruby
client = Valkey.new(
  nodes: [
    { host: "node1.example.com", port: 6379 },
    { host: "node2.example.com", port: 6380 },
  ],
  cluster_mode: true
)
```

Only seed addresses are needed - GLIDE discovers full topology automatically.

## Authentication

```ruby
# Password only
client = Valkey.new(password: "secret")

# Username + password (ACL)
client = Valkey.new(username: "myuser", password: "secret")

# Via URL
client = Valkey.new(url: "redis://myuser:secret@localhost:6379")
```

## TLS/SSL

```ruby
# Basic TLS
client = Valkey.new(
  host: "valkey.example.com",
  port: 6380,
  ssl: true
)

# With custom certificates (mTLS)
client = Valkey.new(
  host: "valkey.example.com",
  port: 6380,
  ssl: true,
  ssl_params: {
    ca_file: "/path/to/ca.crt",
    cert: "/path/to/client.crt",
    key: "/path/to/client.key",
  }
)
```

## Reconnection

```ruby
client = Valkey.new(
  reconnect_attempts: 5,
  reconnect_delay: 0.5,        # initial delay in seconds
  reconnect_delay_max: 5.0,    # max delay cap in seconds
)
```

The client retries with exponential backoff up to the configured maximum.

## Other Options

- **Timeouts**: `timeout: 5.0` (general), `connect_timeout: 3.0` (connection). In seconds.
- **Protocol**: `protocol: :resp2` or `:resp3`.
- **Database**: `db: 2` at init, or `client.select(2)` at runtime.
- **Closing**: `client.close` or `client.disconnect!` (redis-rb alias).

## redis-rb Compatibility

Drop-in replacement: same option names, method names (`set`, `get`, `hset`, `lpush`), `pipelined { }` block syntax, `multi { }` transactions, `redis://` URL schemes, and `disconnect!` alias. Change `require "redis"` to `require "valkey"` and `Redis.new` to `Valkey.new`.
