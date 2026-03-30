# Transparent Compression

Use when values are large and compressible (JSON, text, serialized objects) and you want to reduce network bandwidth and server memory usage. Experimental feature - currently applies only to GET and SET commands.

GLIDE provides automatic client-side compression and decompression of values. When enabled, values are compressed before being sent to the server and decompressed transparently on retrieval. The server stores compressed bytes - it is unaware of compression. Compressed data uses a binary header format that only GLIDE clients with compression support can read. Compression statistics are available via the telemetry system - see [Logging](logging.md) for the `getStatistics()` API.

## Compression Backends

| Backend | ID | Default Level | Level Range | Characteristics |
|---------|----|---------------|-------------|-----------------|
| Zstd | `0x01` | 3 | zstd library range (typically -131072 to 22) | Best compression ratio, moderate CPU |
| LZ4 | `0x02` | 0 | -128 to 12 | Fastest speed, lower compression ratio |

LZ4 level semantics:
- Level > 0: High compression mode (higher = better ratio, slower)
- Level 0: Default balanced mode
- Level < 0: Fast mode with acceleration (more negative = faster, lower ratio)

## Configuration

### CompressionConfig Fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `enabled` | bool | `false` | Whether compression is active |
| `backend` | enum | Zstd | Compression algorithm to use |
| `compression_level` | int or null | Backend default | Algorithm-specific compression level |
| `min_compression_size` | int | 64 bytes | Minimum value size to trigger compression |

The absolute minimum for `min_compression_size` is 6 bytes (5-byte header + 1 byte payload). Values below the configured threshold are sent uncompressed.

## Configuration by Language

### Python

```python
from glide import (
    GlideClientConfiguration,
    NodeAddress,
    CompressionConfiguration,
    CompressionBackend,
)

# ZSTD with defaults
compression = CompressionConfiguration(
    enabled=True,
    backend=CompressionBackend.ZSTD,
    compression_level=3,
    min_compression_size=64,
)

config = GlideClientConfiguration(
    [NodeAddress(host="localhost", port=6379)],
    compression=compression,
)
client = await GlideClient.create(config)
```

### Java

```java
import glide.api.models.configuration.CompressionBackend;
import glide.api.models.configuration.CompressionConfiguration;

// ZSTD with defaults (backend defaults to ZSTD, min size to 64)
CompressionConfiguration zstdConfig = CompressionConfiguration.builder()
    .enabled(true)
    .build();

// LZ4 with custom min size
CompressionConfiguration lz4Config = CompressionConfiguration.builder()
    .enabled(true)
    .backend(CompressionBackend.LZ4)
    .minCompressionSize(128)
    .build();

GlideClientConfiguration clientConfig = GlideClientConfiguration.builder()
    .address(NodeAddress.builder().host("localhost").port(6379).build())
    .compressionConfiguration(zstdConfig)
    .build();

GlideClient client = GlideClient.createClient(clientConfig).get();
```

### Node.js

```typescript
import { CompressionBackend, GlideClient } from "@valkey/valkey-glide";

const client = await GlideClient.createClient({
    addresses: [{ host: "localhost", port: 6379 }],
    compression: {
        enabled: true,
        backend: CompressionBackend.ZSTD,
        minCompressionSize: 64,
    },
});
```

### Go

```go
import "github.com/valkey-io/valkey-glide/go/v2/config"

// ZSTD with defaults
compressionConfig := config.NewCompressionConfiguration()

// ZSTD with custom level and min size
compressionConfig := config.NewCompressionConfiguration().
    WithBackend(config.ZSTD).
    WithCompressionLevel(10).
    WithMinCompressionSize(256)

// LZ4
compressionConfig := config.NewCompressionConfiguration().
    WithBackend(config.LZ4)

clientConfig := config.NewClientConfiguration().
    WithAddress(&config.NodeAddress{Host: "localhost", Port: 6379}).
    WithCompressionConfiguration(compressionConfig)

client, err := glide.NewClient(clientConfig)
```

## Wire Format

Compressed values are prefixed with a 5-byte header:

| Offset | Size | Content |
|--------|------|---------|
| 0-2 | 3 bytes | Magic prefix: `0x00 0x01 0x02` |
| 3 | 1 byte | Format version (currently `0x00`) |
| 4 | 1 byte | Backend ID (`0x01` = Zstd, `0x02` = LZ4) |

LZ4 additionally stores a 4-byte little-endian original size after the header, before the compressed block. This is required because LZ4 block decompression needs the uncompressed size.

## Command Coverage

Compression currently applies to two commands:

| Command | Behavior |
|---------|----------|
| SET | Compress values before sending |
| GET | Decompress values after receiving |

All other commands pass data through without compression processing.

## Compression Decision Logic

When `compress_value` is called, the manager:

1. Checks if compression is enabled - if not, skips
2. Checks if value size meets `min_compression_size` threshold - if not, skips
3. Checks if data already has the compression magic header - if so, skips (avoids double compression)
4. Compresses the data with the configured backend and level
5. Compares compressed size to original - if compressed is not smaller, skips
6. Returns original data on any compression error (graceful fallback)

Decompression reads the backend ID from the header and routes to the correct backend. If the data was compressed with a different backend than the client's configured one, it still decompresses correctly using a static shared backend instance.

## Telemetry Statistics

Compression statistics are tracked globally via the telemetry system and accessible through `client.getStatistics()`:

| Metric | Description |
|--------|-------------|
| `total_values_compressed` | Number of values that were compressed |
| `total_values_decompressed` | Number of values that were decompressed |
| `total_original_bytes` | Sum of original (pre-compression) byte sizes |
| `total_bytes_compressed` | Sum of compressed byte sizes |
| `total_bytes_decompressed` | Sum of decompressed byte sizes |
| `compression_skipped_count` | Times compression was skipped (below threshold, already compressed, or no size reduction) |

### Reading Statistics

```typescript
// Node.js
const stats = client.getStatistics() as Record<string, number>;
const ratio = (1 - stats.total_bytes_compressed / stats.total_original_bytes) * 100;
console.log(`Compression savings: ${ratio.toFixed(1)}%`);
```

```java
// Java
Map<String, String> stats = client.getStatistics();
long original = Long.parseLong(stats.get("total_original_bytes"));
long compressed = Long.parseLong(stats.get("total_bytes_compressed"));
```

```go
// Go
stats := client.GetStatistics()
originalBytes := stats["total_original_bytes"]
compressedBytes := stats["total_bytes_compressed"]
```

## When to Use Compression

Use compression when:
- Values are large (hundreds of bytes or more) and compressible (text, JSON, repeated patterns)
- Network bandwidth is a bottleneck (cross-region replication, cloud environments with bandwidth costs)
- Memory savings on the server are valuable (compressed bytes are stored as-is)

Avoid compression when:
- Values are small (< 64 bytes) - the 5-byte header overhead negates savings
- Values are already compressed or encrypted - random data does not compress
- CPU is the bottleneck - compression adds latency per SET/GET
- Interoperability is required with clients that do not support the GLIDE compression format

## Performance Tradeoffs

| Factor | Higher Compression Level | Lower/Default Level |
|--------|-------------------------|---------------------|
| Compression ratio | Better (smaller output) | Lower (larger output) |
| CPU time on SET | Higher | Lower |
| CPU time on GET | Same (decompression speed is level-independent) | Same |
| Network bandwidth | Lower | Higher |
| Server memory | Lower | Higher |

Zstd level 3 (default) provides a good balance. LZ4 level 0 is the fastest option when compression speed matters more than ratio.

## Zstd vs LZ4 Selection Guidance

- **Zstd** is better for bandwidth-constrained environments and large values where higher compression ratios matter. Good for session data, JSON documents, serialized objects. At level 3 (default), Zstd typically achieves 3:1 to 5:1 compression on JSON/text data.
- **LZ4** is better for latency-sensitive workloads where compression/decompression speed matters more than ratio. Good for high-throughput caching scenarios. LZ4 typically achieves 2:1 to 3:1 but is 2-3x faster than Zstd.

## Cross-Client Compatibility

Compressed values are only readable by GLIDE clients with compression support. A non-GLIDE client reading a compressed key will see the raw compressed bytes (with the magic header prefix). Clients configured with one backend can decompress values compressed by any supported backend - the backend ID in the header determines which decompressor to use.

## Related Features

- [OpenTelemetry](opentelemetry.md) - compression statistics are available alongside OTel metrics via `getStatistics()`
- [Logging](logging.md) - Debug level logs show compression decisions (skipped vs compressed) and statistics
- [Batching](batching.md) - compressed SET/GET commands work within batches
