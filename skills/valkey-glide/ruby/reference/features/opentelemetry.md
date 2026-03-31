# OpenTelemetry Integration

Use when you need distributed tracing, command-level latency metrics, or integration with observability backends (Prometheus, Jaeger, Grafana) for production monitoring. For application-level debug logging, see [Logging](logging.md) instead.

Requires: GLIDE 2.0+.

GLIDE provides integrated OpenTelemetry (OTel) support for tracing and metrics. Once configured, GLIDE emits per-command trace spans and operational metrics - no code changes required beyond initial setup.

OTel can only be initialized once per process. Subsequent calls to `init()` are ignored. To change configuration, restart the process.

## What You Get

### Traces

- A trace span per Valkey command (e.g., `SET`, `GET`, `HSET`)
- A nested `send_command` child span measuring actual server communication time
- Status fields (OK/Error) on each span
- Support for parent span context propagation (link GLIDE spans to your application spans)

### Metrics

Three built-in metrics are emitted out of the box:

- **Timeouts** - Number of requests exceeding the configured timeout duration
- **Retries** - Count of operations retried due to transient errors or topology changes
- **MOVED Errors** - Frequency of cluster slot reallocation responses (indicates slot migrations or stale routing)

Additionally, PubSub subscription synchronization state is reported (out-of-sync events, last sync timestamp).

## Configuration Architecture

The Rust core (`GlideOpenTelemetryConfig`) manages the actual OTel initialization. Language wrappers provide idiomatic configuration objects that map to the core config:

| Core Field | Description |
|-----------|-------------|
| `flush_interval_ms` | Interval between telemetry exports (default: 5000ms) |
| `traces` | Trace exporter endpoint and sample percentage |
| `metrics` | Metrics exporter endpoint |

### Endpoint Protocols

All languages support the same endpoint formats:
- `http://` or `https://` - HTTP/HTTPS export
- `grpc://` - gRPC export
- `file://` - Local file export (development/debugging only)

For file endpoints, the parent directory must exist. If the path is a directory or lacks an extension, data writes to `signals.json` in that directory.

## Python

Python uses separate config classes in `glide_shared.opentelemetry`:

```python
from glide import (
    OpenTelemetryConfig,
    OpenTelemetryTracesConfig,
    OpenTelemetryMetricsConfig,
    OpenTelemetry,
)

config = OpenTelemetryConfig(
    traces=OpenTelemetryTracesConfig(
        endpoint="http://localhost:4317",
        sample_percentage=5,  # 0-100, defaults to 1
    ),
    metrics=OpenTelemetryMetricsConfig(
        endpoint="http://localhost:4317",
    ),
    flush_interval_ms=5000,  # optional, defaults to 5000
)

OpenTelemetry.init(config)
```

Python config classes:
- `OpenTelemetryConfig` - top-level with `traces`, `metrics`, `flush_interval_ms`
- `OpenTelemetryTracesConfig` - `endpoint` (str), `sample_percentage` (int, default 1)
- `OpenTelemetryMetricsConfig` - `endpoint` (str)

## Java

Java uses a builder pattern with the `OpenTelemetry` singleton:

```java
import glide.api.OpenTelemetry;

OpenTelemetry.init(
    OpenTelemetry.OpenTelemetryConfig.builder()
        .traces(
            OpenTelemetry.TracesConfig.builder()
                .endpoint("http://localhost:4318/v1/traces")
                .samplePercentage(10)  // optional, defaults to 1
                .build()
        )
        .metrics(
            OpenTelemetry.MetricsConfig.builder()
                .endpoint("http://localhost:4318/v1/metrics")
                .build()
        )
        .flushIntervalMs(5000L)  // optional, defaults to 5000
        .build()
);
```

Java config classes (all nested in `OpenTelemetry`):
- `OpenTelemetryConfig` - builder with `traces`, `metrics`, `flushIntervalMs`
- `TracesConfig` - builder with `endpoint`, `samplePercentage` (default 1)
- `MetricsConfig` - builder with `endpoint`

Runtime sampling adjustment:
```java
OpenTelemetry.setSamplePercentage(5);  // Change without reinitialization
boolean initialized = OpenTelemetry.isInitialized();
```

### Spring Boot Integration

```properties
spring.data.valkey.valkey-glide.open-telemetry.enabled=true
spring.data.valkey.valkey-glide.open-telemetry.traces-endpoint=http://localhost:4317
spring.data.valkey.valkey-glide.open-telemetry.metrics-endpoint=http://localhost:4317
```

## Node.js

Node.js extends the native config with a `parentSpanContextProvider` callback:

```javascript
import { OpenTelemetry } from "@valkey/valkey-glide";
import { trace } from "@opentelemetry/api";

OpenTelemetry.init({
    traces: {
        endpoint: "http://localhost:4318/v1/traces",
        samplePercentage: 10,
    },
    metrics: {
        endpoint: "http://localhost:4318/v1/metrics",
    },
    flushIntervalMs: 1000,
    parentSpanContextProvider: () => {
        const span = trace.getActiveSpan();
        if (!span) return undefined;
        const ctx = span.spanContext();
        return {
            traceId: ctx.traceId,
            spanId: ctx.spanId,
            traceFlags: ctx.traceFlags,
            traceState: ctx.traceState?.toString(),
        };
    },
});
```

Node.js types:
- `GlideOpenTelemetryConfig` extends `OpenTelemetryConfig` with `parentSpanContextProvider`
- `GlideSpanContext` - `traceId` (32 hex), `spanId` (16 hex), `traceFlags` (0-255), `traceState?` (W3C format)

Runtime methods:
```javascript
OpenTelemetry.setSamplePercentage(5);
OpenTelemetry.setParentSpanContextProvider(newFn);
const pct = OpenTelemetry.getSamplePercentage();
const initialized = OpenTelemetry.isInitialized();
```

## Go

Go uses struct-based configuration with a context-aware span provider:

```go
import glide "github.com/valkey-io/valkey-glide/go/v2"

interval := int64(1000)
config := glide.OpenTelemetryConfig{
    Traces: &glide.OpenTelemetryTracesConfig{
        Endpoint:         "http://localhost:4318/v1/traces",
        SamplePercentage: 10,  // defaults to 1
    },
    Metrics: &glide.OpenTelemetryMetricsConfig{
        Endpoint: "http://localhost:4318/v1/metrics",
    },
    FlushIntervalMs: &interval,  // optional, defaults to 5000
    SpanFromContext: func(ctx context.Context) uint64 {
        if spanPtr, ok := ctx.Value(glide.SpanContextKey).(uint64); ok && spanPtr != 0 {
            return spanPtr
        }
        return 0
    },
}

err := glide.GetOtelInstance().Init(config)
if err != nil {
    log.Fatalf("Failed to initialize OpenTelemetry: %v", err)
}
```

Go types:
- `OpenTelemetryConfig` - `Traces *OpenTelemetryTracesConfig`, `Metrics *OpenTelemetryMetricsConfig`, `FlushIntervalMs *int64`, `SpanFromContext func(ctx context.Context) uint64`
- `OpenTelemetryTracesConfig` - `Endpoint string`, `SamplePercentage int32`
- `OpenTelemetryMetricsConfig` - `Endpoint string`
- `SpanContextKey` - default context key for storing span pointers

## Parent Span Context Propagation

GLIDE command spans can be linked to the application's active OTel span (e.g., an HTTP request handler span), enabling end-to-end distributed tracing. This is configured differently per language:

- **Node.js**: Uses a `parentSpanContextProvider` callback that returns the active span's traceId, spanId, and traceFlags
- **Go**: Uses a `SpanFromContext` function that extracts a span pointer from `context.Context`
- **Java/Python**: Parent context propagation is not yet exposed in the wrapper API

This separation helps distinguish client-side queuing latency from server communication delays by nesting GLIDE spans under application spans.

## Security Best Practices

- Use TLS (`https://` or `grpc://` with TLS) for collector endpoints in production
- Restrict file permissions when using the `file://` exporter
- GLIDE does not include command arguments or key values in trace spans - no sensitive data leaks through tracing
- Review what your collector pipeline forwards to third-party backends

## Grafana Integration

GLIDE exports to any OTel-compatible backend (Prometheus, Jaeger, AWS CloudWatch). For Grafana dashboards:

1. Configure OTel Collector to forward to Prometheus
2. Add Prometheus as Grafana data source
3. Key panels: command latency p50/p95/p99, timeout rate, retry rate, MOVED error rate
4. Use the `send_command` span duration for server-side latency vs total span for client-side

## Sampling Recommendations

| Environment | Sample Percentage | Rationale |
|-------------|-------------------|-----------|
| Development | 100% | Full visibility for debugging |
| Staging | 10-25% | Balance detail and overhead |
| Production | 1-5% | Minimize performance impact |

Higher sampling rates provide more detailed telemetry but impact performance. The sample percentage can be adjusted at runtime (Java, Node.js, Go) without reinitialization.

## Limitations

- **SCAN family commands** (SCAN, SSCAN, HSCAN, ZSCAN) are not included in tracing
- **Lua scripting commands** (EVAL, EVALSHA) are not traced - see [Scripting](scripting.md)
- OTel can only be initialized once per process - configuration changes require restart
- File-based export (`file://`) is intended for development only

## Related Features

- [Architecture Overview](../architecture/overview.md) - the Rust core's `otel_db_semantics` module and per-command span structure
- [Logging](logging.md) - application-level debug logging for connection issues, timeouts, and cluster routing; complements OTel for development debugging
- [Compression](compression.md) - compression statistics are tracked via the telemetry system (`getStatistics()`) alongside OTel metrics
- [AZ Affinity](az-affinity.md) - OTel latency metrics help measure the impact of AZ-affinity routing
