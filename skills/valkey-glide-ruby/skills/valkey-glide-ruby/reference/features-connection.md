# Connection and Configuration (Ruby)

Use when constructing a valkey-rb client, switching between standalone and cluster, configuring TLS, auth, reconnection, or mapping redis-rb config to GLIDE config.

## Single Valkey class

Both standalone and cluster use the same `Valkey` class. Mode is selected by `cluster_mode: true` + `nodes:`.

```ruby
require "valkey"

# Standalone (default)
client = Valkey.new(host: "localhost", port: 6379)

# Cluster
client = Valkey.new(
  nodes: [
    { host: "node1.example.com", port: 6379 },
    { host: "node2.example.com", port: 6380 },
  ],
  cluster_mode: true
)
```

Only seed addresses are needed - topology is discovered automatically.

## Constructor options

The `initialize` method builds an internal `redis[s]://` URI plus a JSON options hash. These kwargs are all recognized:

| Option | Notes |
|--------|-------|
| `host:` | default `"127.0.0.1"` |
| `port:` | default `6379` |
| `nodes:` | array of `{host:, port:}` - required for cluster |
| `cluster_mode:` | `true` for cluster |
| `url:` | `redis://user:pass@host:port/db` or `rediss://...` - parsed first, explicit kwargs override |
| `password:` | plain password (legacy AUTH) |
| `username:` | ACL username - used with `password:` |
| `db:` | integer DB index, must be non-negative |
| `ssl:` | `true` to switch URI scheme to `rediss://` |
| `ssl_params:` | Hash with `ca_file:`, `cert:`, `key:`, `ca_path:`, `root_certs:` |
| `timeout:` | seconds, default `5.0`, maps to `request_timeout` in milliseconds |
| `connect_timeout:` | seconds, maps to `connection_timeout` in milliseconds |
| `protocol:` | `:resp2` (default) or `:resp3` |
| `client_name:` | string |
| `reconnect_attempts:` | integer, non-negative |
| `reconnect_delay:` | seconds (positive number) |
| `reconnect_delay_max:` | seconds; used to derive `exponent_base` internally |
| `tracing:` | **NOT a real option.** OpenTelemetry is configured via `Valkey::OpenTelemetry.init`. |

## URL-based connect

```ruby
client = Valkey.new(url: "redis://user:pass@localhost:6379/0")
client = Valkey.new(url: "rediss://secure.example.com:6380")   # TLS
```

`redis://` and `rediss://` schemes only. Explicit kwargs passed alongside `url:` win over URL-parsed values.

## Authentication

```ruby
# Password only (legacy AUTH)
Valkey.new(password: "secret")

# ACL (username + password)
Valkey.new(username: "myuser", password: "secret")

# Via URL
Valkey.new(url: "redis://myuser:secret@localhost:6379")
```

Passwords and usernames are URL-escaped when building the internal URI.

## TLS / mTLS

```ruby
# Basic TLS
Valkey.new(
  host: "valkey.example.com",
  port: 6380,
  ssl: true
)

# mTLS with client certs
Valkey.new(
  host: "valkey.example.com",
  port: 6380,
  ssl: true,
  ssl_params: {
    ca_file: "/path/to/ca.crt",
    cert: "/path/to/client.crt",     # or an OpenSSL::X509::Certificate
    key: "/path/to/client.key",      # or an OpenSSL::PKey::PKey
    ca_path: "/path/to/ca/dir",      # scans *.crt and *.pem
    root_certs: ["<PEM string>"]     # explicit PEM blobs
  }
)
```

`cert:` and `key:` accept file paths (read as binary) OR objects responding to `to_pem` / `to_der`. File paths are validated at construction time - missing / unreadable files raise `ArgumentError`.

## Reconnection

Three kwargs; the gem derives `exponent_base` internally:

```ruby
Valkey.new(
  reconnect_attempts: 5,         # cap for the growing-delay phase
  reconnect_delay: 0.5,          # base in seconds
  reconnect_delay_max: 5.0       # used to compute exponent_base
)
```

Internally:
- `base_delay * 1000` -> `factor` (milliseconds)
- `exponent_base = max([calculated_base.round, 2])`, where `calculated_base = (max_delay / base_delay) ** (1.0 / retries)`
- `jitter_percent = 0`

Setting only `reconnect_attempts:` (without `reconnect_delay:`) defaults base to 0.5 s; setting only `reconnect_delay_max:` is also accepted.

## Timeouts

```ruby
Valkey.new(
  timeout: 5.0,          # request timeout in seconds (stored as ms)
  connect_timeout: 3.0   # connection establishment timeout in seconds (stored as ms)
)
```

Positive numeric required. Non-numeric or non-positive raises `ArgumentError`.

## Protocol

```ruby
Valkey.new(protocol: :resp3)   # :resp2, :resp3, "resp3", or 3
```

Default is RESP2. The internal config normalizes the value to `"RESP2"` or `"RESP3"`.

## Closing

```ruby
client.close
client.disconnect!     # alias for close
```

Both idempotent. After close, the client's `@connection` pointer is nil-ed out.

## Statistics (process-global)

```ruby
stats = client.statistics           # NOT `get_statistics`
stats[:total_connections]           # flat keys
stats[:total_clients]
stats[:total_values_compressed]
# see features-overview for the full key list
```

Global across all clients in the process. Not per-instance.

## OpenTelemetry (separate init, NOT a constructor flag)

```ruby
Valkey::OpenTelemetry.init(
  traces:  { endpoint: "http://otel:4318/v1/traces", sample_percentage: 10 },
  metrics: { endpoint: "http://otel:4318/v1/metrics" },
  flush_interval_ms: 5000
)

client = Valkey.new                  # traces/metrics flow automatically
```

Call once per process. `tracing:` / `otel:` on `Valkey.new` have no effect.

## redis-rb migration notes

`Redis.new` options that map 1:1: `host`, `port`, `password`, `username`, `db`, `url`, `ssl`, `ssl_params`, `timeout`, `connect_timeout`, `client_name`, `reconnect_attempts`.

Options that **don't exist** in valkey-rb: `driver:`, `sentinels:`, `inherit_socket:`, `id:` (use `client_name:`), `logger:`.

No Sentinel support. Applications using `Redis.new(sentinels: [...])` need to front valkey-rb with a different HA strategy (GLIDE cluster or a proxy).
