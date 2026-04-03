# Sentinel Monitoring and Failure Detection

Use when understanding how Sentinel activates, discovers instances, monitors health via PING/INFO/hello messages, and detects failures (SDOWN/ODOWN/TILT).

Standard Sentinel monitoring, same as Redis. No Valkey-specific changes to the monitoring or failure detection logic.

Source: `src/sentinel.c`. Activation via `--sentinel` flag or binary name containing `valkey-sentinel`/`redis-sentinel`. SDOWN: no valid PING reply for `down_after_period`. ODOWN: quorum Sentinels agree primary is SDOWN. TILT: timer delta > 2s, suspends acting for 30s. Replicas discovered from INFO, Sentinels from `__sentinel__:hello`.
