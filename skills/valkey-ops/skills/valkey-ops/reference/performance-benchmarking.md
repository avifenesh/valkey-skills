# Benchmarking

Use when measuring Valkey throughput or comparing config/version changes.

## Pick a tool

- **`valkey-benchmark`** - ships with every install. Use for ad-hoc throughput checks, smoke tests, sanity-check after a config change. Zero setup.
- **`valkey-perf-benchmark`** - separate Python harness at `valkey-io/valkey-perf-benchmark`. Use when you need commit-to-commit regression testing, statistical analysis across runs, flamegraphs, or a TLS/cluster matrix. Reads full docs from its own repo.

`redis-benchmark` also works against Valkey (same wire protocol). The `USE_REDIS_SYMLINKS=yes` build installs `redis-benchmark` as a symlink to `valkey-benchmark` so old scripts keep working.

## `valkey-benchmark` essential flags

| Flag | Default | Notes |
|------|---------|-------|
| `-c` | 50 | Parallel connections |
| `-n` | 100000 | Total requests |
| `-d` | 3 | Value size in bytes |
| `-P` | 1 | Pipeline depth (`-P 16` simulates pipelined clients) |
| `-t` | all | Comma-separated command list (`-t set,get`) |
| `-q` | off | Quiet - print req/s summary only |
| `--cluster` | off | Cluster mode (hash-tag fan-out) |
| `--tls` / `--cert` / `--key` / `--cacert` | - | TLS |
| `--threads` | 1 | Client I/O threads (different from server `io-threads`) |
| `--csv` | off | Machine-readable output |

## Comparing runs - what to hold constant

When comparing configs, versions, or hardware, keep `-c`, `-P`, `-d`, `-n` identical across runs. Pipelining (`-P`) especially: a 1-connection pipelined run measures different things than a 50-connection unpipelined run. Valkey 9.0's prefetch (`prefetch-batch-max-size`) and zero-copy reply path only kick in with `-P > 1` and enough I/O threads - use pipelining when you want to measure them.

## Isolation heuristics

- Disable other workloads on the host. On shared VMs, benchmark results are noisy and often non-reproducible.
- Set CPU governor to performance: `cpupower frequency-set -g performance`.
- Pin server and client cores via `taskset` - prevents scheduler-induced latency blips.
- Disable persistence during throughput benchmarks (`--save "" --appendonly no`) unless durability overhead is what you're measuring.
- Warm up: discard the first run or use the harness's `warmup` config parameter for read-workload tests (the harness seeds data then reads against a populated keyspace).
- Run at least 3-5 iterations, report mean and std-dev. Coefficient of variation (`sigma/mu * 100%`) under 5% is a reasonable threshold for "this result is reproducible".
- Check CPU saturation on the server: if Valkey's main thread is pinned at 100%, you're measuring CPU limits, not I/O or network.

## What valkey-perf-benchmark adds

The harness builds Valkey from source per commit, runs `valkey-benchmark` under a config-matrix JSON (commands × data sizes × pipeline × io-threads × TLS × cluster modes), collects multi-run stats, and emits markdown + graph comparisons. The GitHub Actions workflow in its repo does continuous regression benchmarking. Use it when you need to prove (or disprove) "did this PR regress performance" before merging - not for one-off tuning validation.
