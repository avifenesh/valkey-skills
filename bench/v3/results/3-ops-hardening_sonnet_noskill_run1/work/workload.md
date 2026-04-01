# Workload Description

Primary data store for user sessions. 16-core machine, 32 GB RAM, approximately 10 million keys expected. Must survive restart. Cache workload with LRU eviction preferred.

## Key characteristics

- Session data: average value size ~2 KB, TTL 30 minutes
- Read-heavy: ~80% GET, ~20% SET
- Peak throughput: ~50,000 ops/sec
- Availability requirement: data must persist across restarts
- Environment: single-node deployment behind application load balancer
- Network: internal network only, but defense-in-depth required
