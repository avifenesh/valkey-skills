# Latency Monitoring

Use when diagnosing latency spikes or understanding the LATENCY command family.

Standard latency monitoring framework - per-event circular buffers of 160 samples, configurable threshold via `latency-monitor-threshold`, LATENCY LATEST/HISTORY/GRAPH/DOCTOR/RESET/HISTOGRAM commands. Instrumented events: command, fork, expire-cycle, eviction-cycle, aof-write, active-defrag-cycle, etc.

## Valkey-Specific Changes

- **COMMANDLOG connection**: LATENCY DOCTOR references COMMANDLOG (Valkey's replacement for SLOWLOG) when suggesting diagnostic thresholds. See [monitoring-commandlog.md](monitoring-commandlog.md).

Source: `src/latency.c`, `src/latency.h`
