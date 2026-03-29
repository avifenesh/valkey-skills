# Testing Tools

Use when setting up integration tests with Valkey, using Testcontainers, or configuring Spring Data Valkey test support.

---

## Testcontainers for Valkey

Testcontainers provides lightweight, disposable Valkey instances for integration testing. Each test gets a fresh Valkey server in a Docker container, eliminating shared state between tests.

### Language Support

| Language | Package | Status | Install |
|----------|---------|--------|---------|
| Go | `testcontainers.org/modules/valkey` | GA (first-class module) | `go get github.com/testcontainers/testcontainers-go/modules/valkey` |
| Node.js | `@testcontainers/valkey` | GA (first-class module) | `npm install @testcontainers/valkey` (v11.13.0+) |
| Java | GenericContainer | No dedicated module | Use `GenericContainer<>("valkey/valkey:9.0")` |
| Python | GenericContainer | No dedicated module | Use `DockerContainer("valkey/valkey:9.0")` |
| Rust | `testcontainers_modules` crate | GA | `cargo add testcontainers_modules --features valkey` |
| Elixir | testcontainers-elixir | GA | Add `{:testcontainers, "~> x.x"}` to mix.exs |

Go and Node.js have first-class Valkey modules with dedicated APIs. Java and
Python lack dedicated Valkey modules - use GenericContainer with the
`valkey/valkey` image. The Java feature request was filed and closed without a
module being created. The testcontainers.com website lists Valkey but the actual
module does not exist in the Java codebase.

### Java Example (GenericContainer)

Since Java lacks a dedicated Valkey module, use GenericContainer:

```java
@Testcontainers
class ValkeyIntegrationTest {

    @Container
    static GenericContainer<?> valkey = new GenericContainer<>("valkey/valkey:9.0")
        .withExposedPorts(6379);

    @Test
    void shouldStoreAndRetrieve() {
        String host = valkey.getHost();
        int port = valkey.getMappedPort(6379);
        // Connect with valkey-java, GLIDE, Jedis, or Lettuce
    }
}
```

### Go Example

```go
func TestWithValkey(t *testing.T) {
    ctx := context.Background()
    container, err := valkey.Run(ctx, "valkey/valkey:8.1")
    require.NoError(t, err)
    defer container.Terminate(ctx)

    endpoint, err := container.ConnectionString(ctx)
    // Connect with valkey-go or go-redis
}
```

### Node.js Example

```typescript
import { ValkeyContainer } from '@testcontainers/valkey';

describe('Valkey integration', () => {
  let container;

  beforeAll(async () => {
    container = await new ValkeyContainer('valkey/valkey:8.1').start();
  });

  afterAll(async () => {
    await container.stop();
  });

  it('should connect', async () => {
    const url = container.getConnectionUrl();
    // Connect with iovalkey or node-redis
  });
});
```

### Container Features

**TLS support** - Configure TLS-enabled Valkey containers for testing encrypted connections. In Go and Node.js, the dedicated module APIs support TLS configuration directly. In Java and Python, configure TLS via command arguments on GenericContainer.

**Snapshotting** - Containers support RDB snapshot configuration for testing persistence behavior.

**Cluster mode** - Test against multi-node cluster topologies. The container orchestrates multiple Valkey nodes and configures them as a cluster.

**Custom configuration** - Pass arbitrary Valkey configuration directives to tailor the test server.

### Valkey Bundle Container

For testing with modules (JSON, Bloom, Search), use the valkey-bundle image:

```java
GenericContainer<?> valkey = new GenericContainer<>("valkey/valkey-bundle:latest")
    .withExposedPorts(6379);
```

This gives you valkey-json, valkey-bloom, valkey-search, and valkey-ldap in a single test container.

---

## Spring Data Valkey Test Support (v1.0.0 GA)

Spring Data Valkey provides first-class testing integration for Spring Boot applications.

### @DataValkeyTest

A slice test annotation that configures only Valkey-related components, keeping tests fast by not loading the full application context:

```java
@DataValkeyTest
class UserCacheTest {

    @Autowired
    private ValkeyTemplate<String, User> valkeyTemplate;

    @Test
    void shouldCacheUser() {
        valkeyTemplate.opsForValue().set("user:1", new User("Alice"));
        User cached = valkeyTemplate.opsForValue().get("user:1");
        assertThat(cached.getName()).isEqualTo("Alice");
    }
}
```

### @ServiceConnection with Testcontainers

Automatically wires a Testcontainers Valkey instance into the Spring context:

```java
@DataValkeyTest
@Testcontainers
class ValkeySliceTest {

    @Container
    @ServiceConnection
    static ValkeyContainer valkey = new ValkeyContainer("valkey/valkey:8.1");

    @Autowired
    private ValkeyTemplate<String, String> valkeyTemplate;

    @Test
    void shouldConnect() {
        valkeyTemplate.opsForValue().set("test", "value");
        assertThat(valkeyTemplate.opsForValue().get("test")).isEqualTo("value");
    }
}
```

The `@ServiceConnection` annotation eliminates manual connection configuration - Spring Boot auto-detects the container's host and port.

### Docker Compose Service Detection

Spring Boot detects Valkey services in `compose.yaml` and auto-configures connections during development and testing:

```yaml
services:
  valkey:
    image: valkey/valkey:8.1
    ports:
      - "6379:6379"
```

Spring Boot maps the service to Valkey connection properties automatically when `spring-boot-docker-compose` is on the classpath.

---

## Integration Testing Patterns

### Isolated Tests with Fresh State

Each test should start with a clean Valkey instance. With Testcontainers, each test class gets its own container. For shared containers, call `FLUSHALL` in a `@BeforeEach` setup method.

### Testing Pub/Sub

Use a CountDownLatch or similar synchronization mechanism to coordinate publisher and subscriber in tests. Subscribe first, then publish, then await the latch with a timeout.

### Testing Cluster Behavior

For cluster-specific tests (slot migration, failover), use Testcontainers cluster mode or the `create-cluster` utility from the Valkey source tree (`utils/create-cluster/create-cluster start && create-cluster create`).

### CI Pipeline Considerations

- Testcontainers requires Docker in CI - ensure your CI environment has Docker available
- Use fixed image tags (e.g., `valkey/valkey:8.1`) rather than `latest` for reproducible builds
- Consider container reuse (`testcontainers.reuse.enable=true`) to speed up local development cycles
- For CI without Docker, use embedded Valkey test servers or mock the client layer

---

## See Also

- [Framework Integrations](frameworks.md) - Spring Data Valkey, Django, Rails setup
- [CLI and Benchmarking Tools](cli-benchmarking.md) - valkey-cli for manual testing and debugging
- [Infrastructure as Code](iac.md) - Terraform and Helm for provisioning test environments
