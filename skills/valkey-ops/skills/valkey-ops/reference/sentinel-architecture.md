# Sentinel Architecture and Failure Detection

Use when understanding how Sentinel provides high availability for non-clustered Valkey.

Standard Redis Sentinel architecture applies - monitoring, notification, automatic failover, SDOWN/ODOWN states, quorum/majority, replica selection algorithm. See Redis Sentinel docs for full details.

## Valkey-Specific Names

- Binary: `valkey-sentinel` or `valkey-server ... --sentinel`
- Sentinel listens on port 26379 (same as Redis)
- Sentinel sets `server.protected_mode = 0` on activation (verified in `sentinel.c`)

## Replica Selection Terms

Valkey uses `replica` terminology. Config parameter is `replica-priority` (not `slave-priority`). Set `replica-priority 0` to exclude a node from promotion.

## Key Timing Defaults (source-verified, same as Redis)

| Constant | Default |
|----------|---------|
| `down-after-milliseconds` | 30000ms |
| `failover-timeout` | 180000ms |
| `parallel-syncs` | 1 |

## Deployment Requirement

Deploy at least 3 Sentinel instances on independent infrastructure. Never deploy 2 Sentinels. See sentinel-sentinel-deployment.md for step-by-step setup.
