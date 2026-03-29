# Java Client

Use when building Java/JVM applications with Valkey GLIDE - CompletableFuture-based async API for standalone and cluster modes.

## Installation

**Requirements:** JDK 11+ (JDK 8 supported from GLIDE 2.3)

### Gradle

Requires the OS detector plugin for platform-specific native binaries:

```gradle
plugins {
    id "com.google.osdetector" version "1.7.3"
}

dependencies {
    implementation group: 'io.valkey', name: 'valkey-glide',
                  version: '2.+', classifier: osdetector.classifier
}
```

### Maven

```xml
<dependency>
    <groupId>io.valkey</groupId>
    <artifactId>valkey-glide</artifactId>
    <classifier>${os.detected.classifier}</classifier>
    <version>[2.0.0,)</version>
</dependency>
```

Maven requires the `os-maven-plugin` extension to resolve `${os.detected.classifier}`.

**Platform support:** Linux (x86_64, arm64), macOS (Apple Silicon, x86_64), Windows (x86_64), Alpine Linux.

---

## Client Classes

| Class | Package | Mode | Description |
|-------|---------|------|-------------|
| `GlideClient` | `glide.api` | Standalone | Single-node or primary+replicas |
| `GlideClusterClient` | `glide.api` | Cluster | Valkey Cluster with auto-topology |

Both extend `BaseClient` and return `CompletableFuture` from all command methods.

---

## Standalone Connection

```java
import glide.api.GlideClient;
import glide.api.models.configuration.GlideClientConfiguration;
import glide.api.models.configuration.NodeAddress;

public class QuickStart {
    public static void main(String[] args) throws Exception {
        GlideClientConfiguration config = GlideClientConfiguration.builder()
            .address(NodeAddress.builder()
                .host("localhost")
                .port(6379)
                .build())
            .requestTimeout(5000)
            .build();

        try (GlideClient client = GlideClient.createClient(config).get()) {
            client.set("greeting", "Hello from GLIDE").get();
            String value = client.get("greeting").get();
            System.out.println("Got: " + value);
        }
    }
}
```

The `GlideClient` implements `AutoCloseable` - use try-with-resources to ensure cleanup.

---

## Cluster Connection

```java
import glide.api.GlideClusterClient;
import glide.api.models.configuration.GlideClusterClientConfiguration;
import glide.api.models.configuration.NodeAddress;
import glide.api.models.configuration.ReadFrom;

GlideClusterClientConfiguration config = GlideClusterClientConfiguration.builder()
    .address(NodeAddress.builder().host("node1.example.com").port(6379).build())
    .address(NodeAddress.builder().host("node2.example.com").port(6380).build())
    .readFrom(ReadFrom.PREFER_REPLICA)
    .build();

GlideClusterClient client = GlideClusterClient.createClient(config).get();

client.set("key", "value").get();
String value = client.get("key").get();

client.close();
```

Only seed node addresses are needed - GLIDE discovers the full cluster topology automatically.

---

## Configuration

All configuration classes use the Lombok builder pattern. Package: `glide.api.models.configuration`.

### GlideClientConfiguration

```java
import glide.api.models.configuration.*;

GlideClientConfiguration config = GlideClientConfiguration.builder()
    .address(NodeAddress.builder().host("localhost").port(6379).build())
    .useTLS(true)
    .readFrom(ReadFrom.PREFER_REPLICA)
    .credentials(ServerCredentials.builder()
        .username("myuser")
        .password("mypass")
        .build())
    .requestTimeout(5000)
    .reconnectStrategy(BackoffStrategy.builder()
        .numOfRetries(5)
        .factor(100)
        .exponentBase(2)
        .jitterPercent(20)
        .build())
    .databaseId(0)
    .clientName("my-app")
    .inflightRequestsLimit(1000)
    .subscriptionConfiguration(subscriptionConfig)
    .advancedConfiguration(
        AdvancedGlideClientConfiguration.builder()
            .connectionTimeout(500)
            .build())
    .readOnly(true)
    .build();
```

### GlideClusterClientConfiguration

Adds `periodicChecks` for topology refresh and supports sharded PubSub.

```java
GlideClusterClientConfiguration config = GlideClusterClientConfiguration.builder()
    .address(NodeAddress.builder().host("node1.example.com").port(6379).build())
    .readFrom(ReadFrom.AZ_AFFINITY)
    .clientAz("us-east-1a")
    .build();
```

---

## Configuration Details

### NodeAddress

```java
// Default: localhost:6379
NodeAddress addr = NodeAddress.builder().build();

// Custom
NodeAddress addr = NodeAddress.builder()
    .host("my.server.com")
    .port(6380)
    .build();
```

### ServerCredentials

Supports password-based or IAM authentication (mutually exclusive). See `features/tls-auth.md` for TLS and authentication details.

```java
// Password-based
ServerCredentials creds = ServerCredentials.builder()
    .username("myuser")
    .password("mypass")
    .build();

// IAM-based
ServerCredentials creds = ServerCredentials.builder()
    .username("myuser")
    .iamConfig(IamAuthConfig.builder()
        .clusterName("my-cluster")
        .service(ServiceType.ELASTICACHE)
        .region("us-east-1")
        .build())
    .build();
```

### BackoffStrategy

```java
BackoffStrategy strategy = BackoffStrategy.builder()
    .numOfRetries(5)       // escalation attempts before constant retry
    .factor(100)           // base delay in milliseconds
    .exponentBase(2)       // exponential growth factor
    .jitterPercent(20)     // optional jitter percentage
    .build();
```

Formula: `factor * (exponentBase ^ N)` with optional `jitterPercent` as a percentage of the computed duration. See [connection-model](../architecture/connection-model.md) for full retry strategy details.

### ReadFrom

Enum in `glide.api.models.configuration.ReadFrom`:

| Value | Behavior |
|-------|----------|
| `PRIMARY` | All reads to primary (default) |
| `PREFER_REPLICA` | Round-robin replicas, fallback to primary |
| `AZ_AFFINITY` | Prefer same-AZ replicas (requires `clientAz`) |
| `AZ_AFFINITY_REPLICAS_AND_PRIMARY` | Same-AZ replicas, then primary, then remote |

AZ Affinity strategies require Valkey 8.0+ and `clientAz` must be set. See `features/az-affinity.md` for detailed AZ routing behavior.

---

## Error Handling

All async methods return `CompletableFuture`. Errors surface as `ExecutionException` wrapping the actual error.

```java
import java.util.concurrent.ExecutionException;

try {
    String value = client.get("key").get();
} catch (ExecutionException e) {
    Throwable cause = e.getCause();
    if (cause instanceof glide.api.models.exceptions.RequestException) {
        System.err.println("Request failed: " + cause.getMessage());
    }
}
```

For non-blocking error handling:

```java
client.get("key")
    .thenAccept(value -> System.out.println("Got: " + value))
    .exceptionally(e -> {
        System.err.println("Failed: " + e.getMessage());
        return null;
    });
```

---

## Batching

See `features/batching.md` for detailed batching API patterns across all languages.

### Transaction (Atomic)

```java
import glide.api.models.Transaction;

Transaction tx = new Transaction();
tx.set("key", "value");
tx.incr("counter");
tx.get("key");
Object[] result = client.exec(tx).get();
// result: ["OK", 1L, "value"]
```

### Batch (Non-Atomic Pipeline)

```java
import glide.api.models.Batch;

Batch batch = new Batch();
batch.set("k1", "v1");
batch.set("k2", "v2");
batch.get("k1");
Object[] result = client.exec(batch).get();
```

---

## Architecture Notes

- **Communication layer**: JNI with Protobuf serialization for all commands
- All command methods return `CompletableFuture<T>` - call `.get()` to block, or chain with `.thenAccept()` / `.thenApply()`
- Single multiplexed connection per node
- Native library is platform-specific - the `classifier` in the dependency resolves to the correct binary
- `GlideClient` implements `AutoCloseable` for try-with-resources support
- The `GlideString` class supports binary-safe string operations for keys and values

---

## Platform Classifier

A platform-specific classifier is mandatory in Maven/Gradle dependencies. Without it, the native binary will not be found at runtime. Available classifiers: `osx-aarch_64`, `osx-x86_64`, `linux-aarch_64`, `linux-x86_64`, `linux_musl-aarch_64`, `linux_musl-x86_64`, `windows-x86_64`.

Use `os-maven-plugin` (Maven) or `osdetector-gradle-plugin` (Gradle) for automatic platform detection. An uber JAR containing all native libraries is available from GLIDE 2.3 as an alternative.

---

## JVM Tuning Notes

No official JVM tuning guidance is published. Relevant considerations:
- Monitor native memory with `-XX:NativeMemoryTracking=summary` since the Rust core allocates outside the JVM heap
- The inflight request limit defaults to 1000; tune `requestTimeout` based on workload

---

## Ecosystem Integrations

### Jedis Compatibility Layer

A drop-in Jedis replacement is available as `valkey-glide-jedis-compatibility`. It maps `Jedis`, `JedisCluster`, `UnifiedJedis`, `JedisPool`, and `JedisPooled` to GLIDE implementations.

### Spring Boot

Spring Data Valkey provides GLIDE as a first-class driver. The Jedis compatibility layer with Spring Data Redis's Jedis connection factory is also a potential migration path.
