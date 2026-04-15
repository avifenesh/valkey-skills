# Connection and Configuration (Java)

Use when creating a GLIDE Java client, choosing between standalone and cluster mode, or configuring connection options.

## Client Types

`GlideClient` connects to standalone Valkey servers. `GlideClusterClient` connects to Valkey Cluster and auto-discovers topology from seed nodes.

Both return `CompletableFuture` from `createClient()` - the connection is async.

## Standalone Client

```java
import glide.api.GlideClient;
import glide.api.models.configuration.*;

GlideClientConfiguration config = GlideClientConfiguration.builder()
    .address(NodeAddress.builder().host("localhost").port(6379).build())
    .build();

GlideClient client = GlideClient.createClient(config).get();
String pong = client.ping().get(); // "PONG"
client.close();
```

## Cluster Client

```java
import glide.api.GlideClusterClient;
import glide.api.models.configuration.*;

GlideClusterClientConfiguration config = GlideClusterClientConfiguration.builder()
    .address(NodeAddress.builder().host("node1.example.com").port(6379).build())
    .address(NodeAddress.builder().host("node2.example.com").port(6380).build())
    .useTLS(true)
    .build();

GlideClusterClient client = GlideClusterClient.createClient(config).get();
```

## NodeAddress

Defaults to `localhost:6379` when fields are omitted:

```java
NodeAddress.builder().build();                        // localhost:6379
NodeAddress.builder().port(6380).build();             // localhost:6380
NodeAddress.builder().host("my.cloud.com").port(12345).build();
```

## Authentication

Password-based or IAM-based (mutually exclusive):

```java
// Password auth
ServerCredentials creds = ServerCredentials.builder()
    .username("myuser")
    .password("secret")
    .build();

// IAM auth (AWS ElastiCache/MemoryDB)
ServerCredentials iamCreds = ServerCredentials.builder()
    .username("myuser")  // required for IAM
    .iamConfig(IamAuthConfig.builder()
        .clusterName("my-cluster")
        .service(ServiceType.ELASTICACHE)
        .region("us-east-1")
        .refreshIntervalSeconds(300)
        .build())
    .build();
```

## ReadFrom Strategy

```java
GlideClientConfiguration.builder()
    .readFrom(ReadFrom.PRIMARY)                       // default - always primary
    .readFrom(ReadFrom.PREFER_REPLICA)                // round-robin replicas, fallback to primary
    .readFrom(ReadFrom.AZ_AFFINITY)                   // prefer same-AZ replicas
    .readFrom(ReadFrom.AZ_AFFINITY_REPLICAS_AND_PRIMARY) // same-AZ replicas then primary
    .build();
```

For AZ-aware routing, also set `clientAZ`:

```java
GlideClusterClientConfiguration.builder()
    .readFrom(ReadFrom.AZ_AFFINITY)
    .clientAZ("us-east-1a")
    .build();
```

## Reconnection Strategy

Exponential backoff with jitter: `rand(0 ... factor * (exponentBase ^ N))`.

```java
BackoffStrategy strategy = BackoffStrategy.builder()
    .numOfRetries(5)
    .exponentBase(2)
    .factor(100)          // 100ms base delay
    .jitterPercent(20)
    .build();

GlideClientConfiguration.builder()
    .reconnectStrategy(strategy)
    .build();
```

## Common Configuration Options

```java
GlideClientConfiguration.builder()
    .address(NodeAddress.builder().port(6379).build())
    .useTLS(true)
    .credentials(creds)
    .requestTimeout(2000)            // ms, default 250
    .clientName("my-app")
    .databaseId(1)                   // standalone only
    .inflightRequestsLimit(1000)     // default 1000
    .protocol(ProtocolVersion.RESP3) // default RESP3
    .lazyConnect(true)               // defer connection until first command
    .reconnectStrategy(strategy)
    .build();
```

## Lazy Connect

When `lazyConnect(true)`, no connection is made during `createClient()`. The first command triggers connection, which may add latency. The `connectionTimeout` governs that initial connection; `requestTimeout` starts after connection is established.

## Database Selection (Standalone Only)

```java
// At config time
GlideClientConfiguration.builder().databaseId(2).build();

// At runtime
client.select(3).get();
```

## Resource Management

GlideClient implements `AutoCloseable`. Use try-with-resources or call `close()`:

```java
try (GlideClient client = GlideClient.createClient(config).get()) {
    client.set("key", "value").get();
}
```
