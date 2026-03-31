# Benchmarking

Use when measuring Valkey throughput, comparing performance across versions or
configurations, validating tuning changes, or establishing performance baselines
for capacity planning.

---

## Tool Comparison

| Tool | Scope | Use When |
|------|-------|----------|
| `valkey-benchmark` | Quick, built-in | Ad-hoc throughput checks, smoke tests, comparing config changes on a single instance |
| `valkey-perf-benchmark` | Full harness | Comparing commits/versions, CI regression testing, TLS/cluster matrix, statistical analysis, flamegraphs |

`valkey-benchmark` ships with Valkey and requires zero setup. Use it for quick
spot-checks. `valkey-perf-benchmark` is a separate Python project that automates
server build, setup, teardown, multi-run statistical analysis, and result
comparison - use it for structured, repeatable performance evaluations.

## valkey-benchmark (Built-in)

Ships with every Valkey installation at `src/valkey-benchmark`.

### Quick Usage

```bash
# Default: 50 parallel connections, 100K requests, 3-byte payload
valkey-benchmark

# Specific commands with options
valkey-benchmark -t set,get -c 100 -n 1000000 -d 256 -q

# Pipeline mode (batch N commands per round-trip)
valkey-benchmark -t set -c 50 -n 1000000 -P 16 -q

# Cluster mode
valkey-benchmark --cluster -t set,get -c 100 -n 1000000 -q

# TLS
valkey-benchmark --tls --cert ./client.crt --key ./client.key --cacert ./ca.crt \
  -t set,get -c 100 -n 500000 -q

# CSV output for parsing
valkey-benchmark -t set,get -c 50 -n 100000 --csv
```

### Key Flags

| Flag | Description | Default |
|------|-------------|---------|
| `-c` | Parallel connections | 50 |
| `-n` | Total requests | 100000 |
| `-d` | Data size (bytes) | 3 |
| `-P` | Pipeline depth | 1 (no pipelining) |
| `-t` | Comma-separated command list | all |
| `-q` | Quiet - show only req/sec summary | off |
| `--cluster` | Cluster mode | off |
| `--tls` | Enable TLS | off |
| `--csv` | CSV output | off |
| `--threads` | Client I/O threads | 1 |

### Interpreting Results

Each command reports requests per second and latency percentiles. When
comparing, always keep these constant: connection count (`-c`), pipeline
depth (`-P`), data size (`-d`), and request count (`-n`). Run multiple
iterations and discard the first (warmup).

## valkey-perf-benchmark (CI/Regression Harness)

Repository: [valkey-io/valkey-perf-benchmark](https://github.com/valkey-io/valkey-perf-benchmark)

A Python-based harness that automates end-to-end performance benchmarking.
It clones Valkey source for each target commit, builds it, starts/stops
the server, runs `valkey-benchmark` under controlled conditions, and
collects structured results with statistical analysis.

### Features

- Builds Valkey from source per commit for reproducible comparisons
- Supports TLS and cluster mode matrix testing
- CPU pinning via `taskset` for isolated measurements
- Multi-run averaging with standard deviation and coefficient of variation
- Comparison reports between commits/versions (markdown + graphs)
- Flamegraph generation via `perf` profiling
- Full-text search (FTS) benchmarking with the valkey-search module
- Grafana dashboards for visualizing results over time
- GitHub Actions workflow for continuous benchmarking

### Prerequisites

- Linux (required for `taskset` CPU pinning)
- Python 3.6+
- Git, gcc, make (Valkey build tools)

### Setup

```bash
git clone https://github.com/valkey-io/valkey-perf-benchmark.git
cd valkey-perf-benchmark
python3 -m venv venv
. venv/bin/activate
pip install --require-hashes -r requirements.txt
```

### Usage

```bash
# Benchmark current HEAD with defaults
python benchmark.py

# Benchmark a specific commit
python benchmark.py --commits abc1234

# Compare HEAD against a baseline branch
python benchmark.py --commits HEAD --baseline unstable

# Multiple runs for statistical reliability
python benchmark.py --commits HEAD --runs 5

# Use a pre-existing Valkey directory (skip clone/build)
python benchmark.py --valkey-path /path/to/valkey

# Benchmark against an already-running server
python benchmark.py --valkey-path /path/to/valkey --use-running-server

# Server-only or client-only mode (split across machines)
python benchmark.py --mode server
python benchmark.py --mode client --target-ip 192.168.1.100

# Custom valkey-benchmark binary
python benchmark.py --valkey-benchmark-path /usr/local/bin/valkey-benchmark
```

### Configuration

Benchmark configs are JSON files in `configs/`. Each object defines a test
matrix - commands, data sizes, pipelines, I/O threads, cluster/TLS modes.

```json
[
  {
    "requests": [10000000],
    "keyspacelen": [10000000],
    "data_sizes": [16, 64, 256],
    "pipelines": [1, 10, 100],
    "commands": ["SET", "GET"],
    "cluster_mode": "yes",
    "tls_mode": "yes",
    "warmup": 10,
    "io-threads": [1, 4, 8],
    "server_cpu_range": "0-1",
    "client_cpu_range": "2-3"
  }
]
```

Key config parameters: `requests`, `keyspacelen`, `data_sizes`, `pipelines`,
`clients`, `commands`, `cluster_mode`, `tls_mode`, `warmup`, `io-threads`,
`server_cpu_range`, `client_cpu_range`.

When `warmup` is set for read commands, the harness seeds data first, runs
a warmup pass, then executes the measured benchmark.

### Comparing Results

```bash
# Compare two result sets
python utils/compare_benchmark_results.py \
  --baseline results/commit1/metrics.json \
  --new results/commit2/metrics.json \
  --output comparison.md

# With graphs
python utils/compare_benchmark_results.py \
  --baseline results/commit1/metrics.json \
  --new results/commit2/metrics.json \
  --output comparison.md --graphs --graph-dir graphs/

# Filter to RPS or latency only
python utils/compare_benchmark_results.py \
  --baseline results/commit1/metrics.json \
  --new results/commit2/metrics.json \
  --output comparison.md --metrics rps --graphs
```

Statistical output includes mean, standard deviation, and coefficient of
variation (CV = sigma/mu x 100%). Lower CV indicates more consistent results.

### Results Structure

```
results/<commit-id>/
  logs.txt          # Benchmark output
  metrics.json      # Structured performance data
  valkey_log_*.log  # Server logs
```

## Benchmarking Best Practices

1. **Isolate the machine** - disable other workloads, pin CPUs, disable
   frequency scaling (`cpupower frequency-set -g performance`)
2. **Disable persistence** - use `--save ""` and `appendonly no` unless
   you are specifically benchmarking durability impact
3. **Warm up** - discard the first run or use the `warmup` config parameter
4. **Multiple runs** - at least 3-5 runs; report mean and standard deviation
5. **Match production topology** - test with the same cluster size, TLS
   settings, and client count you will deploy
6. **Control data size** - vary `-d` to match your actual value sizes
7. **Check CPU saturation** - if Valkey is pinned at 100% on one core,
   you are measuring CPU limits not network or I/O capacity

---

## See Also

- [Latency diagnosis](latency.md) - when benchmarks reveal latency problems
- [I/O threads](io-threads.md) - tuning thread count for throughput
- [Durability vs performance](durability.md) - persistence impact on throughput
- [Memory optimization](memory.md) - encoding and fragmentation affecting benchmarks
- [Capacity planning](../operations/capacity-planning.md) - using benchmark results for sizing
