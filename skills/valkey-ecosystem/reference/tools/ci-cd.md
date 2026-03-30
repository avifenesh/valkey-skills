# CI/CD Integration

Use when adding Valkey to CI pipelines for integration testing - GitHub Actions service containers, dedicated actions, GitLab CI services, and test data setup patterns.

---

## GitHub Actions: Service Container

The most common approach. GitHub Actions natively supports service containers alongside your job.

### Basic Service Container

```yaml
jobs:
  test:
    runs-on: ubuntu-latest
    services:
      valkey:
        image: valkey/valkey:9.0
        ports:
          - 6379:6379
        options: >-
          --health-cmd "valkey-cli ping"
          --health-interval 10s
          --health-timeout 5s
          --health-retries 5

    steps:
      - uses: actions/checkout@v4
      - name: Run integration tests
        env:
          VALKEY_URL: redis://localhost:6379
        run: npm test
```

The `options` block configures Docker health checks. GitHub Actions waits for the service to be healthy before running steps.

### Variants

- **With authentication**: Add `env: VALKEY_EXTRA_FLAGS: "--requirepass testpassword"` to the service and update the health check to `valkey-cli -a testpassword ping`
- **With modules**: Swap the image to `valkey/valkey-bundle:latest` for valkey-json, valkey-bloom, valkey-search, and valkey-ldap

### Container-to-Container Networking

When your test job also runs in a container, use the service name as hostname instead of `localhost`:

```yaml
jobs:
  test:
    runs-on: ubuntu-latest
    container: node:20
    services:
      valkey:
        image: valkey/valkey:9.0
        ports:
          - 6379:6379
    steps:
      - uses: actions/checkout@v4
      - run: npm test
        env:
          VALKEY_URL: redis://valkey:6379
```

---

## felipet/valkey-action

A dedicated GitHub Action that deploys a Valkey server as a step. Has minimal
adoption - most projects use the service container pattern above instead, which
is the approach used in Valkey's own CI and in projects like LaunchDarkly.

```yaml
steps:
  - name: Deploy Valkey
    uses: felipet/valkey-action@v1
    with:
      host port: 6379       # Optional, default 6379
      container port: 6379   # Optional, default 6379
      valkey version: '9.0'  # Optional, default 'latest'

  - name: Run tests
    run: npm test
    env:
      VALKEY_URL: redis://localhost:6379
```

Use any tag from Docker Hub for `valkey version`. Pin to a specific version for reproducible builds.

---

## GitLab CI

GitLab CI supports service containers via the `services` keyword.

```yaml
integration-tests:
  image: node:20
  services:
    - name: valkey/valkey:9.0
      alias: valkey
  variables:
    VALKEY_URL: "redis://valkey:6379"
  script:
    - npm ci
    - npm test
```

In GitLab CI, services are accessible by their alias (or image name with slashes replaced by dashes). The `alias` keyword provides a clean hostname.

For the bundle image with modules:

```yaml
services:
  - name: valkey/valkey-bundle:latest
    alias: valkey
```

### Sentinel Testing in CI

`mini-ci-cd/valkey-with-embedded-sentinel` packages both valkey-server and
valkey-sentinel in a single container for CI/CD pipelines where testing Sentinel
failover without multi-container orchestration is needed.

---

## Testcontainers in CI

Testcontainers programmatically manages Valkey containers within test code. It requires Docker access in the CI environment.

**Advantages over service containers**:
- Per-test isolation - each test class gets a fresh instance
- Container configuration lives with test code, not CI config
- Portable across CI providers

**CI requirements**:
- GitHub Actions: Docker is available by default on `ubuntu-latest`
- GitLab CI: Use Docker-in-Docker (`dind`) or a shell executor with Docker
- CircleCI: Use a `machine` executor or `setup_remote_docker`

```yaml
# GitHub Actions - Testcontainers just works
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: npm test  # Testcontainers creates containers internally
```

Pin image tags in test code for reproducibility:

```typescript
new ValkeyContainer('valkey/valkey:9.0.3')
```

See the [Testing Tools](testing.md) reference for language-specific Testcontainers examples and Spring Data Valkey test support.

---

## Test Data Setup Patterns

### Cache Warming

Pre-load test data before running tests. Use `valkey-cli` in a setup step:

```yaml
steps:
  - name: Seed test data
    run: |
      valkey-cli -h localhost -p 6379 SET user:1 '{"name":"alice"}'
      valkey-cli -h localhost -p 6379 SET user:2 '{"name":"bob"}'
      valkey-cli -h localhost -p 6379 LPUSH queue:tasks task1 task2 task3
```

### Bulk Loading via Pipeline

For larger datasets, use pipelining for faster ingestion:

```yaml
steps:
  - name: Bulk load test data
    run: |
      cat test/fixtures/seed-data.txt | valkey-cli --pipe -h localhost -p 6379
```

The pipe protocol format expects lines like `SET key value\r\n`.

### Flush Between Test Suites

When sharing a single Valkey instance across multiple test suites, run `valkey-cli FLUSHALL` between suites to reset state.

### RDB Snapshot Restore

For complex test datasets, prepare a `dump.rdb` file and mount its directory as the service volume at `/data`. Valkey loads the snapshot on startup.

---

## See Also

- [Docker](docker.md) - Image selection, tags, and Docker Compose patterns
- [Testing Tools](testing.md) - Testcontainers setup and Spring test support
- [Security](security.md) - Provenance verification and supply chain checks for CI
- [Infrastructure as Code](iac.md) - Terraform and Helm for staging environments
