# CLI and Benchmarking Tools

Use when working with Valkey command-line tools for server interaction, diagnostics, or performance measurement.

---

## valkey-cli

The interactive command-line interface for Valkey servers. Drop-in replacement for redis-cli with identical usage.

### Basic Usage

```bash
valkey-cli                                    # connect to localhost:6379
valkey-cli -h host -p 6380 -a password        # remote with auth
valkey-cli SET key value                       # single command
valkey-cli --tls --cert ./client.crt --key ./client.key --cacert ./ca.crt
```

Command history is stored in `~/.valkeycli_history` and persists across sessions.

### Cluster Mode

```bash
# Connect in cluster mode - auto-redirects MOVED/ASK responses
valkey-cli -c -h cluster-node -p 6379

# Scan all nodes in the cluster
valkey-cli --cluster info host:port
valkey-cli --cluster check host:port
```

In cluster mode (`-c`), the CLI follows redirections automatically when a key lives on a different node. Without `-c`, you see `MOVED` errors and must reconnect manually.

### Latency Monitoring

```bash
# Continuous latency sampling (Ctrl-C to stop)
valkey-cli --latency

# Latency with history over time
valkey-cli --latency-history

# Latency distribution (heatmap-style)
valkey-cli --latency-dist
```

These modes measure round-trip time for PING commands and report min/max/avg statistics. Useful for diagnosing network or server latency issues. For deeper latency analysis, see the **valkey-ops** skill.

### Stat Mode

```bash
# Real-time server stats refreshed every second
valkey-cli --stat

# Custom refresh interval (every 5 seconds)
valkey-cli --stat -i 5
```

Stat mode displays a rolling view of key metrics: commands/sec, memory usage, connected clients, and keyspace hits/misses.

### Pub/Sub Monitoring

```bash
# Subscribe to channels
valkey-cli SUBSCRIBE channel1 channel2

# Pattern subscribe
valkey-cli PSUBSCRIBE "events.*"

# Monitor all commands hitting the server (use sparingly in production)
valkey-cli MONITOR
```

### Bulk Operations via Pipelining

```bash
# Pipe commands from a file
cat commands.txt | valkey-cli --pipe

# Generate SET commands and pipe them in
for i in $(seq 1 1000); do echo "SET key:$i value:$i"; done | valkey-cli --pipe
```

The `--pipe` mode uses the Valkey inline protocol for efficient bulk ingestion. It reports inserted, errors, and replies per second.

### Useful Diagnostic Commands

```bash
valkey-cli INFO                         # all server info sections
valkey-cli INFO memory                  # specific section
valkey-cli --scan --pattern "user:*"    # safe key scan (unlike KEYS)
valkey-cli DBSIZE                       # key count
valkey-cli SLOWLOG GET 25               # slow query log
```

---

## valkey-server

The Valkey server binary. Drop-in replacement for redis-server.

```bash
# Start with default configuration
valkey-server

# Start with a config file
valkey-server /etc/valkey/valkey.conf

# Override specific settings
valkey-server --port 6380 --daemonize yes --loglevel notice

# Start in Sentinel mode
valkey-server /etc/valkey/sentinel.conf --sentinel
```

For server configuration, deployment, and operations, see the **valkey-ops** skill.

---

## valkey-benchmark

Built-in load testing and performance measurement tool. Ships with the Valkey distribution.

### Basic Usage

```bash
valkey-benchmark                                    # default: 50 clients, 100k requests
valkey-benchmark -c 100 -n 1000000 -t set,get       # custom clients, requests, commands
valkey-benchmark -n 100000 EVAL "return redis.call('set',KEYS[1],ARGV[1])" 1 key:__rand_int__ value
```

### Key Options

| Flag | Description | Since |
|------|-------------|-------|
| `-c <clients>` | Number of parallel connections (default: 50) | - |
| `-n <requests>` | Total number of requests (default: 100000) | - |
| `-d <size>` | Data size of SET/GET value in bytes (default: 3) | - |
| `-t <tests>` | Comma-separated list of commands to benchmark | - |
| `-P <numreq>` | Pipeline N requests per connection | - |
| `-q` | Quiet mode - show only query/sec results | - |
| `--threads <n>` | Multi-threaded execution | - |
| `--cluster` | Cluster mode benchmarking | - |
| `-r <keyspacelen>` | Use random keys from keyspace of this size | - |
| `--csv` | Output in CSV format | - |
| `--rps <rate>` | Target requests per second rate control | 9.0 |
| `--sequential` | Populate entire keyspace sequentially | 9.0 |
| `--warmup <sec>` | Warmup period before measurement starts | 9.1 |
| `--duration <sec>` | Run for a fixed duration instead of request count | 9.1 |

### Multi-Threaded and Pipelining

```bash
valkey-benchmark --threads 4 -c 200 -n 2000000 -t set,get   # multi-threaded
valkey-benchmark -P 16 -n 1000000 -t set,get                  # pipeline 16 per round trip
```

Multi-threaded mode distributes clients across threads. Match thread count to CPU cores on the benchmarking machine. Pipelining batches multiple commands per network round trip - a depth of 16-32 is typical for measuring throughput capacity.

### Valkey 9.0 Benchmark Additions

Valkey 9.0 added significant benchmark capabilities:

- **RPS control** (`--rps`) - cap request rate to measure latency under controlled
  load instead of saturating the server
- **Sequential keyspace** (`--sequential`) - populate entire keyspace in order
- **MGET test support** - benchmark multi-key read patterns
- **Multiple arbitrary commands** - benchmark custom command sequences in a single run
- **RDMA and MPTCP support** - benchmark over RDMA transports and multi-path TCP
- **Multiple random/sequential placeholders** - complex key patterns in a single
  command template

### Valkey 9.1 Benchmark Additions

- **RPS histogram display** - shows request rate distribution over the run
- **Warmup period** (`--warmup`) - discards initial measurements affected by
  connection setup and cache warming
- **Duration mode** (`--duration`) - run for a fixed time instead of a fixed
  request count, better for steady-state analysis

### HDR Histogram Latency

valkey-benchmark produces HDR histogram output showing latency distribution at p50, p99, p99.9, and p99.99 percentiles. Tail latency percentiles are more informative than averages for production capacity planning.

---

## valkey-perf-benchmark

Advanced benchmarking tool from the Valkey project for more sophisticated performance testing scenarios.

- **Repo**: [valkey-io/valkey-perf-benchmark](https://github.com/valkey-io/valkey-perf-benchmark)

### Features

- **Cross-commit comparison** - compare performance across git commits for
  regression detection
- **TLS and cluster mode** - measure TLS overhead; distribute across cluster nodes
- **CPU pinning** - isolate benchmark threads to specific cores for reproducibility
- **Flamegraph generation** - automatic CPU profiling with flamegraph output
- **FTS benchmarking** - Full-Text Search performance testing with valkey-search
  module
- **Grafana dashboards** - visualize benchmark results across runs
- **GitHub Actions integration** - continuous benchmarking in CI pipelines

### When to Use Which Tool

| Scenario | Tool |
|----------|------|
| Quick smoke test | valkey-benchmark |
| Measuring throughput capacity | valkey-benchmark with `--threads` and `-P` |
| TLS performance impact | valkey-perf-benchmark |
| Cluster vs standalone comparison | valkey-perf-benchmark |
| CI performance regression testing | valkey-perf-benchmark |
| Simple latency check | valkey-cli `--latency` |

For production performance investigation methodology, see the **valkey-ops** skill.

---

## See Also

- [Framework Integrations](frameworks.md) - Spring, Django, Rails, and queue framework setup
- [Testing Tools](testing.md) - Testcontainers and integration testing
- [Migration from Redis](migration.md) - redis-cli to valkey-cli is a binary swap with identical commands
