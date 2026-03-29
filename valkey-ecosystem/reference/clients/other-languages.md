# Other Language Client Libraries

Use when building Valkey applications in Go, Rust, .NET/C#, PHP, Swift, Scala, or C, choosing between native Valkey clients and Redis-compatible alternatives, or evaluating GLIDE availability for these languages.

---

> Go, Rust, .NET/C#, PHP, Swift, Scala, and C clients for Valkey.

## Go

### valkey-go (Official, Native)

valkey-go is purpose-built for Valkey - not a fork of an existing Redis client. It features auto-pipelining that automatically batches concurrent commands for higher throughput.

| | |
|---|---|
| **Version** | 1.0.73 (check pkg.go.dev for latest) |
| **Go** | 1.24+ |
| **Server** | Valkey 7.2+ |
| **Install** | `go get github.com/valkey-io/valkey-go` |

```go
import "github.com/valkey-io/valkey-go"

client, err := valkey.NewClient(valkey.ClientOption{
    InitAddress: []string{"localhost:6379"},
})
defer client.Close()

ctx := context.Background()
err = client.Do(ctx, client.B().Set().Key("key").Value("value").Build()).Error()
result, err := client.Do(ctx, client.B().Get().Key("key").Build()).ToString()
```

Key features: auto-pipelining (concurrent commands batched automatically - up to ~14x throughput vs go-redis in benchmarks), cluster and sentinel support, client-side caching, Pub/Sub, Streams, Lua scripting, TLS, RDMA, context-based cancellation, AZ-affinity routing.

Notable packages: `valkeycompat` (go-redis compatibility adapter), `valkeyaside` (cache-aside pattern with object mapping), `valkeylock` (distributed locks with client-side caching), `valkeyotel` (OpenTelemetry), `valkeyprob` (probabilistic data structures).

With 609 GitHub stars (highest of any standalone Valkey-native client) and roughly monthly releases, valkey-go has strong momentum in the Go ecosystem.

### go-redis (Compatible)

go-redis works with Valkey by changing only the server address:

```go
import "github.com/redis/go-redis/v9"

client := redis.NewClient(&redis.Options{
    Addr: "valkey-server:6379",
})
```

go-redis is widely used and well-documented. It works with Valkey via RESP compatibility but will not track Valkey-specific features. Key gap: AZ-affinity routing was requested but closed without implementation in go-redis - available natively in valkey-go. PubSub in TLS-only clusters may connect to the wrong port.

### GLIDE Go (Official, GA)

GLIDE Go reached GA status. It provides the same Rust-core benefits as other GLIDE clients - AZ-affinity, auto-reconnect, production-hardened defaults.

See the **valkey-glide** skill for GLIDE Go API details and usage patterns.

### Migration: go-redis to valkey-go

Unlike most other language migrations, moving from go-redis to valkey-go involves API differences. valkey-go uses a builder pattern for commands rather than individual methods:

```go
// go-redis
client.Set(ctx, "key", "value", 0)

// valkey-go
client.Do(ctx, client.B().Set().Key("key").Value("value").Build())
```

The valkey-go project provides a migration guide. The auto-pipelining benefit often justifies the effort for high-throughput applications.

Go has first-class Testcontainers support via `testcontainers.org/modules/valkey`.

## Rust

### redis-rs (Compatible)

redis-rs is the primary Rust client for Redis-compatible servers. It explicitly supports Valkey in its documentation and is the foundation upon which GLIDE's core is built.

| | |
|---|---|
| **Crate** | `redis` |
| **Install** | `cargo add redis` |
| **Server** | Valkey 7.2+, Redis 6.2+ |

```rust
use redis::Commands;

let client = redis::Client::open("redis://valkey-server:6379/")?;
let mut con = client.get_connection()?;
con.set("key", "value")?;
let result: String = con.get("key")?;
```

Key features: sync and async (tokio, async-std), cluster support (`ClusterClient`), connection pooling (r2d2/deadpool), Pub/Sub, Streams, Lua scripting, TLS.

### No Native Valkey Rust Binding

There is no dedicated Valkey Rust client yet. While GLIDE's core is written in Rust, it does not expose a Rust-language binding - the Rust code serves as the engine for Python, Java, Node.js, and other language wrappers. redis-rs remains the recommended and only practical choice for Rust applications connecting to Valkey.

## .NET / C#

### StackExchange.Redis (Compatible, Valkey-Aware)

StackExchange.Redis is the dominant .NET client for Redis-compatible servers. It explicitly lists Valkey as supported and has added Valkey-specific detection.

| | |
|---|---|
| **Version** | 2.12.8 (March 2026) |
| **NuGet** | `StackExchange.Redis` |
| **Install** | `dotnet add package StackExchange.Redis` |

```csharp
using StackExchange.Redis;

var connection = ConnectionMultiplexer.Connect("valkey-server:6379");
var db = connection.GetDatabase();

db.StringSet("key", "value");
string result = db.StringGet("key");
```

Valkey-specific features:
- `GetProductVariant` method to detect Valkey vs Redis
- Multi-DB support on Valkey clusters (Valkey 9.0 feature)
- Cluster, Sentinel, and standalone modes

### Valkey GLIDE C# (Preview)

GLIDE C# is in preview. Its API is designed to be compatible with StackExchange.Redis v2.8.58, enabling migration with minimal code changes.

GLIDE C# reached v0.9.0 (September 2025) and is maintained in its own repo (valkey-glide-csharp). Since GLIDE C# is still in preview, StackExchange.Redis remains the production recommendation for .NET applications. See the **valkey-glide** skill for GLIDE C# API details and current status.

## PHP

### phpredis (Compatible, Recommended)

phpredis is a C extension providing a PHP API for Redis-compatible servers. It is the recommended PHP client for Valkey due to its performance.

| | |
|---|---|
| **Version** | 6.3.0 (November 2025) |
| **Install** | `pecl install redis` |
| **PHP** | 7.4+ |

```php
$client = new Redis();
$client->connect('valkey-server', 6379);

$client->set('key', 'value');
$result = $client->get('key');
```

Key features: C extension (significantly faster than pure PHP), cluster and sentinel support, Streams, Pub/Sub, pipelines, serialization (PHP, igbinary, msgpack), LZ4/ZSTD compression.

### Predis (Compatible)

Predis is a pure PHP client - no C extension required.

| | |
|---|---|
| **Version** | 3.4.2 (March 2026) |
| **Install** | `composer require predis/predis` |

```php
$client = new Predis\Client('tcp://valkey-server:6379');

$client->set('key', 'value');
$result = $client->get('key');
```

Predis explicitly brands as "Redis/Valkey client for PHP" (7,751 stars). Version 3.4.0 brought a 25% handshake performance improvement, retry support, and `VRANGE` command support (Valkey-specific).

Choose Predis when:
- You cannot install C extensions (shared hosting)
- You need pure PHP for portability
- Development environments where phpredis installation is complex

### Valkey GLIDE PHP (1.0 GA)

GLIDE PHP reached 1.0.0 GA in January 2026 - a significant milestone. It is maintained in its own repo (valkey-glide-php). See the **valkey-glide** skill for API details.

## Swift

### valkey-swift (Official)

valkey-swift is the official Swift client for Valkey, reaching 1.0 GA in February 2026 and 1.1.0 in March 2026.

| | |
|---|---|
| **Version** | 1.1.0 (March 2026) |
| **Stars** | 124 |
| **Install** | Swift Package Manager |

```swift
// Package.swift
.package(url: "https://github.com/valkey-io/valkey-swift", from: "1.1.0")
```

This is a new client (not a fork) designed for server-side Swift (Linux + macOS). It went from 0.1.0 to 1.1.0 in 8 months, showing strong development velocity.

Key features (1.0+): persistent connection pool, all Valkey v9.0.2 commands, pipelining, transactions, cluster mode with automatic routing/MOVED/ASK redirection/topology refresh/replica reads, standalone with replica support.

1.1.0 additions: retry support for pipelined commands, graceful cluster shutdown, regular topology refresh for standalone client, Valkey command-line tool written in valkey-swift.

## Scala

### valkey4cats

valkey4cats provides a functional Scala client for Valkey, built on GLIDE with Cats Effect and Fs2 for streaming. By the author of redis4cats (the popular Scala Redis client). Still under construction but shows GLIDE being used as a foundation for language-specific clients.

```scala
// Functional, resource-safe Valkey access
import dev.profunktor.valkey4cats.Valkey4Cats

val resource = Valkey4Cats[IO].make("redis://valkey-server:6379")
resource.use { client =>
  for {
    _ <- client.set("key", "value")
    v <- client.get("key")
  } yield v
}
```

Choose valkey4cats for Typelevel stack applications (Cats Effect, http4s, Fs2).

## C

### libvalkey (Official)

libvalkey is the official C client for Valkey, maintained by the Valkey project. It supports both standalone and cluster modes with RESP2 and RESP3 protocol versions.

| | |
|---|---|
| **Version** | 0.4.0 (check GitHub tags for latest) |
| **Repo** | [valkey-io/libvalkey](https://github.com/valkey-io/libvalkey) |
| **Install** | Build from source (make or CMake) |
| **Platforms** | Linux, FreeBSD, macOS, Windows |

```c
#include <valkey/valkey.h>

valkeyContext *c = valkeyConnect("127.0.0.1", 6379);
valkeyReply *reply = valkeyCommand(c, "SET %s %s", "key", "value");
freeReplyObject(reply);

reply = valkeyCommand(c, "GET %s", "key");
printf("GET key: %s\n", reply->str);
freeReplyObject(reply);

valkeyFree(c);
```

Key features:
- Printf-like command invocation
- Synchronous and asynchronous operation (with libevent, libev, libuv, etc.)
- Cluster mode via `valkeyClusterContext`
- Optional TLS, MPTCP, and RDMA support
- Both RESP2 and RESP3 protocols

Build with make:

```bash
# Basic build
sudo make install

# With TLS and RDMA
sudo USE_TLS=1 USE_RDMA=1 make install
```

Build with CMake:

```bash
mkdir build && cd build
cmake -DCMAKE_BUILD_TYPE=RelWithDebInfo ..
sudo make install
```

libvalkey is the successor to hiredis for Valkey deployments. It is used as the C foundation for higher-level client bindings including libvalkey-py.

**1.0 Roadmap**: A 1.0.0 milestone is open on GitHub. Remaining work includes switching to opaque structs for ABI stability, hiding `valkeyContext` internals, renaming `freeReplyObject` to `valkeyFreeReplyObject`, and documenting the ABI versioning policy.

### libvalkey-py (Python Bindings)

libvalkey-py is a Python C extension that wraps the protocol parsing code in libvalkey. It accelerates parsing of multi-bulk replies for Python Valkey clients.

| | |
|---|---|
| **PyPI** | `libvalkey` |
| **Install** | `pip install libvalkey` |
| **Python** | 3.9+ |
| **Repo** | [valkey-io/libvalkey-py](https://github.com/valkey-io/libvalkey-py) |

```python
import libvalkey

reader = libvalkey.Reader()
reader.feed(b"$5\r\nhello\r\n")
result = reader.gets()  # b'hello'
```

libvalkey-py provides a `Reader` class for parsing RESP protocol data from a stream. It does not handle I/O directly - it is used as a performance-critical parser within higher-level clients like valkey-py. When installed, valkey-py automatically uses libvalkey for parsing instead of its pure-Python parser.

Supports unicode decoding with configurable encoding and error handlers:

```python
reader = libvalkey.Reader(encoding="utf-8", errors="strict")
```

### hiredis-cluster

hiredis-cluster is a C client for Valkey and Redis Cluster, maintained by Ericsson and Nordix.

| | |
|---|---|
| **Version** | 0.14.0 (August 2024) |
| **Install** | Build from source |
| **Repo** | GitHub: Nordix/hiredis-cluster (104 stars) |

Uses `redisClusterContext` with `redisClusterCommand()` for SET/GET operations. Still actively maintained (last pushed March 2026). Primarily used for embedded systems, high-performance C applications, and as the foundation for higher-level client wrappers.

For new projects targeting Valkey, prefer libvalkey over hiredis-cluster.

## Summary Table

| Language | Native Valkey Client | Compatible Redis Client | GLIDE Status |
|----------|---------------------|------------------------|--------------|
| Go | valkey-go (1.0.73) | go-redis | GA |
| Rust | None | redis-rs | No Rust binding |
| .NET/C# | None | StackExchange.Redis (2.12.8) | Preview (0.9.0) |
| PHP | None | phpredis (6.3.0), Predis (3.4.2) | 1.0 GA |
| Swift | valkey-swift (1.1.0) | None | Not available |
| Scala | valkey4cats | GLIDE (underlying) | Not available |
| C | libvalkey (0.4.0) | hiredis-cluster (0.14.0) | Not available |
| Ruby | None | redis-rb | In development (separate repo) |
| C++ | None | None | In development (separate repo) |

## Cross-References

- `clients/landscape.md` - overall client decision framework and RESP compatibility notes
- `clients/python.md` - Python clients
- `clients/nodejs.md` - Node.js clients
- `clients/java.md` - Java clients
- **valkey-glide** skill - GLIDE API details for Go, C#, PHP
- `modules/overview.md` - module system; module commands accessible via `custom_command` in any GLIDE client
- `modules/bloom.md` - Bloom filter commands; valkey-go has `valkeyprob` package for probabilistic structures
