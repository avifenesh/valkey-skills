Use when configuring TLS, authentication, Lua scripting, handling errors, or working with CompletableFuture patterns in GLIDE Java.

## Contents

- TLS Configuration (line 14)
- Authentication (line 50)
- Lua Scripting (line 81)
- Error Types (line 190)
- CompletableFuture Patterns (line 203)
- Custom Commands (line 243)
- OpenTelemetry (line 261)
- Advanced Configuration (line 291)

## TLS Configuration

### Basic TLS

```java
GlideClientConfiguration config = GlideClientConfiguration.builder()
    .address(NodeAddress.builder().host("tls.example.com").port(6380).build())
    .useTLS(true)
    .build();
```

### Advanced TLS Options

```java
// Insecure TLS (self-signed certs) - not for production
GlideClientConfiguration.builder()
    .useTLS(true)
    .advancedConfiguration(AdvancedGlideClientConfiguration.builder()
        .tlsAdvancedConfiguration(TlsAdvancedConfiguration.builder()
            .useInsecureTLS(true).build())
        .build())
    .build();

// Custom root certificates from PEM
TlsAdvancedConfiguration tlsConfig = TlsAdvancedConfiguration.builder()
    .rootCertificates(Files.readAllBytes(Path.of("/path/to/ca.pem")))
    .build();

// From Java KeyStore (JKS or PKCS12)
TlsAdvancedConfiguration tlsConfig = TlsAdvancedConfiguration.fromKeyStore(
    "/path/to/truststore.jks", "password".toCharArray(), "JKS");

// Connection timeout (default 2000ms)
AdvancedGlideClientConfiguration.builder().connectionTimeout(500).build();
```

## Authentication

### Password Auth

```java
ServerCredentials creds = ServerCredentials.builder()
    .password("secret")        // password-only (username defaults to "default")
    .build();

ServerCredentials creds = ServerCredentials.builder()
    .username("admin")
    .password("secret")
    .build();
```

### IAM Auth (AWS)

```java
ServerCredentials creds = ServerCredentials.builder()
    .username("myuser")
    .iamConfig(IamAuthConfig.builder()
        .clusterName("my-cluster")
        .service(ServiceType.ELASTICACHE)  // or ServiceType.MEMORYDB
        .region("us-east-1")
        .refreshIntervalSeconds(300)       // default 300s
        .build())
    .build();
```

Password and IAM are mutually exclusive - setting both throws `IllegalArgumentException`.

## Lua Scripting

### Script Object

`Script` implements `AutoCloseable`. Use try-with-resources to manage the script lifecycle:

```java
import glide.api.models.Script;

try (Script luaScript = new Script("return 'Hello'", false)) {
    String result = (String) client.invokeScript(luaScript).get();
    // result == "Hello"
}
```

The `binaryOutput` constructor parameter controls whether the response is decoded as String or raw bytes.

### Script with Keys and Arguments

```java
import glide.api.models.commands.ScriptOptions;

try (Script luaScript = new Script("return { KEYS[1], ARGV[1] }", false)) {
    ScriptOptions options = ScriptOptions.builder()
        .key("mykey")
        .arg("myarg")
        .build();
    Object[] result = (Object[]) client.invokeScript(luaScript, options).get();
    // result[0] == "mykey", result[1] == "myarg"
}
```

### Binary Script with GlideString

```java
import glide.api.models.commands.ScriptOptionsGlideString;
import static glide.api.models.GlideString.gs;

try (Script luaScript = new Script(gs("return { KEYS[1], ARGV[1] }"), true)) {
    ScriptOptionsGlideString options = ScriptOptionsGlideString.builder()
        .key(gs("mykey"))
        .arg(gs("myarg"))
        .build();
    Object[] result = (Object[]) client.invokeScript(luaScript, options).get();
}
```

### Read-Only Script (Valkey 7.0+)

```java
// No keys or arguments
String result = (String) client.evalReadOnly("return 'Hello'").get();

// With keys and arguments
Object[] result = (Object[]) client.evalReadOnly(
    "return {KEYS[1], ARGV[1]}",
    new String[]{"key1"}, new String[]{"arg1"}).get();
```

### Read-Only Script by SHA (Valkey 7.0+)

```java
try (Script luaScript = new Script("return {KEYS[1], ARGV[1]}", false)) {
    // invokeScript triggers SCRIPT LOAD internally, making the SHA available
    client.invokeScript(luaScript).get();
    Object[] result = (Object[]) client.evalshaReadOnly(
        luaScript.getHash(), new String[]{"key1"}, new String[]{"arg1"}).get();
}
```

### Script Source (Valkey 8.0+)

```java
String source = client.scriptShow(luaScript.getHash()).get();
```

### Script Management

```java
// Check if scripts exist in the cache
Boolean[] exists = client.scriptExists(
    new String[]{luaScript.getHash()}).get();

// Flush script cache
client.scriptFlush().get();
client.scriptFlush(FlushMode.ASYNC).get();

// Kill a running script
client.scriptKill().get();

// Set debug mode (YES, SYNC, NO)
client.scriptDebug(ScriptDebugMode.YES).get();
```

### Server-Side Functions (FUNCTION)

```java
String libName = client.functionLoad(luaCode, true).get();  // replace=true
Object result = client.fcall("myfunction").get();
Object result2 = client.fcall("myfunc", new String[]{"key1"}, new String[]{"arg1"}).get();
Map<String, Object>[] libs = client.functionList(true).get(); // withCode=true
client.functionFlush(FlushMode.ASYNC).get();
client.functionDelete("mylib").get();

// Dump and restore (binary serialized)
byte[] dump = client.functionDump().get();
client.functionRestore(dump, FunctionRestorePolicy.REPLACE).get();
```

## Error Types

All exceptions extend `GlideException` (which extends `RuntimeException`):

| Exception | When |
|-----------|------|
| `RequestException` | Server reported an error for the command |
| `TimeoutException` | Request exceeded `requestTimeout` |
| `ConnectionException` | Connection lost (may be temporary - client reconnects) |
| `ClosingException` | Client is closed and no longer usable |
| `ExecAbortException` | Atomic batch (transaction) was aborted |
| `ConfigurationError` | Invalid client configuration |

## CompletableFuture Patterns

```java
// Blocking
String value = client.get("key").get();

// With timeout
String value = client.get("key").get(5, TimeUnit.SECONDS);

// Async chaining
client.set("counter", "0")
    .thenCompose(ok -> client.incr("counter"))
    .thenAccept(val -> System.out.println("Counter: " + val))
    .exceptionally(ex -> { System.err.println(ex.getMessage()); return null; });

// Parallel
CompletableFuture<String> f1 = client.get("key1");
CompletableFuture<String> f2 = client.get("key2");
CompletableFuture.allOf(f1, f2).get();
```

### Error Handling

```java
try {
    String value = client.get("key").get();
} catch (ExecutionException e) {
    Throwable cause = e.getCause();
    if (cause instanceof RequestException) {
        System.err.println("Server error: " + cause.getMessage());
    } else if (cause instanceof TimeoutException) {
        System.err.println("Timed out");
    } else if (cause instanceof ConnectionException) {
        System.err.println("Connection lost (will reconnect)");
    } else if (cause instanceof ClosingException) {
        System.err.println("Client closed");
    }
}
```

## Custom Commands

For commands not yet in the API:

```java
// Standalone
Object result = client.customCommand(new String[]{"MEMORY", "USAGE", "mykey"}).get();

// Cluster - auto-routed
ClusterValue<Object> result = clusterClient.customCommand(
    new String[]{"MEMORY", "USAGE", "mykey"}).get();

// Cluster - explicit route
ClusterValue<Object> result = clusterClient.customCommand(
    new String[]{"INFO", "SERVER"},
    new SlotKeyRoute("mykey", SlotType.PRIMARY)).get();
```

## OpenTelemetry

Initialize once per process, before creating any clients:

```java
import glide.api.OpenTelemetry;
import glide.api.OpenTelemetry.OpenTelemetryConfig;
import glide.api.OpenTelemetry.TracesConfig;
import glide.api.OpenTelemetry.MetricsConfig;

OpenTelemetry.init(OpenTelemetryConfig.builder()
    .traces(TracesConfig.builder()
        .endpoint("http://localhost:4318/v1/traces")
        .samplePercentage(5)   // optional, default 1
        .build())
    .metrics(MetricsConfig.builder()
        .endpoint("http://localhost:4318/v1/metrics")
        .build())
    .flushIntervalMs(5000L)    // optional, default 5000
    .build());
```

Supported endpoint protocols: `http://`, `https://`, `grpc://`, `file://`.

Adjust sampling at runtime without reinitializing:

```java
OpenTelemetry.setSamplePercentage(10);
```

## Advanced Configuration

```java
AdvancedGlideClientConfiguration.builder()
    .connectionTimeout(500)                   // TCP/TLS connect timeout, default 2000ms
    .tcpNoDelay(true)                         // disable Nagle's algorithm, default true
    .pubsubReconciliationIntervalMs(5000)     // PubSub reconciliation interval
    .tlsAdvancedConfiguration(TlsAdvancedConfiguration.builder()
        .useInsecureTLS(true).build())        // skip cert validation (dev only)
    .build();
```
