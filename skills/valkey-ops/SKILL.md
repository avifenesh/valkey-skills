---
name: valkey-ops
description: "Use when deploying, configuring, monitoring, troubleshooting, or maintaining self-hosted Valkey. Covers installation, HA with Sentinel, cluster mode, persistence, replication, security, performance tuning, Kubernetes deployment, upgrades, and capacity planning."
version: 1.0.0
argument-hint: "[config, deploy, monitor, or troubleshoot topic]"
---

# Valkey Operations Reference

53 source-verified reference docs for deploying and operating self-hosted Valkey. All config defaults verified against actual Valkey source code.

## Routing

- Install, build from source, package manager, Docker, Compose, systemd, bare metal, multi-instance -> Deployment
- Config tuning, maxmemory, eviction, encoding thresholds, lazyfree, logging, CPU pinning, workload presets, pubsub buffers -> Configuration
- High availability, Sentinel, failover detection, quorum, split-brain, min-replicas -> Sentinel
- Cluster setup, hash slots, resharding, node add/remove, atomic migration, replica migration, consistency -> Cluster
- Persistence, RDB, AOF, hybrid, fsync, BGSAVE, backup, restore, disaster recovery -> Persistence
- Replication, primary-replica, REPLICAOF, backlog, diskless sync, dual-channel, replication lag -> Replication
- ACL, TLS, certificates, mutual TLS, protected mode, rename-command, hardening, network security -> Security
- Monitoring, INFO, metrics, Prometheus, Grafana, alerting, commandlog, slow log -> Monitoring
- Performance, I/O threads, memory fragmentation, defragmentation, latency, durability, client-side caching, CLIENT TRACKING, benchmarking -> Performance
- OOM, out of memory, crashes, slow commands, replication lag diagnosis, cluster partitions, network splits, diagnostics -> Troubleshooting
- Version upgrades, compatibility, Redis to Valkey migration, rolling upgrade -> Upgrades
- Kubernetes, Helm, operators, StatefulSet, PVC, probes, resource sizing, kernel tuning -> Kubernetes
- Capacity planning, memory sizing, connection planning, cluster sizing -> Operations
- Pre-launch check, production readiness, go-live checklist -> Production Checklist


## Deployment

| Topic | Reference |
|-------|-----------|
| Package managers, building from source, build flags | [install](reference/deployment/install.md) |
| Docker images, Compose patterns, volume mounts | [docker](reference/deployment/docker.md) |
| systemd service, kernel tuning, multi-instance | [bare-metal](reference/deployment/bare-metal.md) |


## Configuration

| Topic | Reference |
|-------|-----------|
| Essential parameters with verified defaults | [essentials](reference/configuration/essentials.md) |
| Eviction policies, LRU/LFU tuning | [eviction](reference/configuration/eviction.md) |
| Memory encoding thresholds per data type | [encoding](reference/configuration/encoding.md) |
| Config presets by workload (cache, store, session, queue) | [workload-presets](reference/configuration/workload-presets.md) |
| Lazy free config (UNLINK, async eviction/expiry) | [lazyfree](reference/configuration/lazyfree.md) |
| Logging, OOM score, shutdown, CPU pinning, unix sockets | [advanced](reference/configuration/advanced.md) |
| Pub/Sub buffer limits, keyspace notifications | [pubsub](reference/configuration/pubsub.md) |


## Sentinel (High Availability)

| Topic | Reference |
|-------|-----------|
| How Sentinel works, failure detection, election | [architecture](reference/sentinel/architecture.md) |
| Step-by-step deployment, config directives | [deployment-runbook](reference/sentinel/deployment-runbook.md) |
| Split-brain prevention, min-replicas settings | [split-brain](reference/sentinel/split-brain.md) |


## Cluster

| Topic | Reference |
|-------|-----------|
| Network requirements, config, cluster creation, hash slots | [setup](reference/cluster/setup.md) |
| Resharding, adding/removing nodes, atomic migration (9.0) | [resharding](reference/cluster/resharding.md) |
| Manual failover, health checks, replica migration, scaling | [operations](reference/cluster/operations.md) |
| Consistency guarantees, write safety, partition behavior | [consistency](reference/cluster/consistency.md) |


## Persistence

| Topic | Reference |
|-------|-----------|
| RDB configuration, save directives, BGSAVE | [rdb](reference/persistence/rdb.md) |
| AOF configuration, fsync policies, hybrid mode | [aof](reference/persistence/aof.md) |
| Backup scripts, disaster recovery, FLUSHALL recovery | [backup-recovery](reference/persistence/backup-recovery.md) |


## Replication

| Topic | Reference |
|-------|-----------|
| Primary-replica setup, REPLICAOF, sync mechanisms | [setup](reference/replication/setup.md) |
| Backlog sizing, diskless sync, dual-channel, Docker/NAT | [tuning](reference/replication/tuning.md) |
| min-replicas safety, critical warnings, data loss prevention | [safety](reference/replication/safety.md) |


## Security

| Topic | Reference |
|-------|-----------|
| ACL users, roles, categories, practical examples | [acl](reference/security/acl.md) |
| TLS setup, certificates, mutual TLS, auto-reload | [tls](reference/security/tls.md) |
| Defense in depth, protected mode, network hardening | [hardening](reference/security/hardening.md) |
| Disabling dangerous commands via rename-command and ACL | [rename-commands](reference/security/rename-commands.md) |


## Monitoring

| Topic | Reference |
|-------|-----------|
| INFO sections, critical metrics, diagnostic commands | [metrics](reference/monitoring/metrics.md) |
| Prometheus exporter setup, scrape configs | [prometheus](reference/monitoring/prometheus.md) |
| Grafana dashboards, panel definitions, PromQL queries | [grafana](reference/monitoring/grafana.md) |
| Alert rules YAML, thresholds, Alertmanager routing | [alerting](reference/monitoring/alerting.md) |
| Commandlog (slow/large request/reply tracking) | [commandlog](reference/monitoring/commandlog.md) |


## Performance

| Topic | Reference |
|-------|-----------|
| I/O threads config, when to enable, thread count | [io-threads](reference/performance/io-threads.md) |
| maxmemory, eviction, encoding, fragmentation | [memory](reference/performance/memory.md) |
| Latency diagnosis workflow, LATENCY DOCTOR, watchdog | [latency](reference/performance/latency.md) |
| Durability vs performance spectrum, TCP tuning | [durability](reference/performance/durability.md) |
| Active defragmentation config and monitoring | [defragmentation](reference/performance/defragmentation.md) |
| Client-side caching (CLIENT TRACKING) | [client-caching](reference/performance/client-caching.md) |
| valkey-benchmark, valkey-perf-benchmark, best practices | [benchmarking](reference/performance/benchmarking.md) |


## Troubleshooting

| Topic | Reference |
|-------|-----------|
| Out of memory: symptoms, diagnosis, resolution | [oom](reference/troubleshooting/oom.md) |
| Replication lag: diagnosis, backlog, buffer tuning | [replication-lag](reference/troubleshooting/replication-lag.md) |
| Slow commands: commandlog, common culprits, fixes | [slow-commands](reference/troubleshooting/slow-commands.md) |
| Cluster partitions: network splits, recovery | [cluster-partitions](reference/troubleshooting/cluster-partitions.md) |
| Fork latency, memory testing, diagnostic commands | [diagnostics](reference/troubleshooting/diagnostics.md) |


## Upgrades

| Topic | Reference |
|-------|-----------|
| Version compatibility, RDB versions, feature matrix | [compatibility](reference/upgrades/compatibility.md) |
| Redis to Valkey migration, 3 methods | [migration](reference/upgrades/migration.md) |
| Rolling upgrades for Sentinel and Cluster | [rolling-upgrade](reference/upgrades/rolling-upgrade.md) |


## Kubernetes

| Topic | Reference |
|-------|-----------|
| Official and Bitnami Helm charts, key values | [helm](reference/kubernetes/helm.md) |
| Official, Hyperspike, and SAP operators, CRD examples | [operators](reference/kubernetes/operators.md) |
| StatefulSet patterns, PVCs, probes, resource sizing, PDB | [statefulset](reference/kubernetes/statefulset.md) |
| Kernel tuning, Docker/NAT, monitoring sidecars | [tuning-k8s](reference/kubernetes/tuning-k8s.md) |


## Operations

| Topic | Reference |
|-------|-----------|
| Memory sizing, connection planning, cluster sizing | [capacity-planning](reference/operations/capacity-planning.md) |


## Production Checklist

| Topic | Reference |
|-------|-----------|
| Pre-launch checklist: system, config, security, monitoring, backup, HA | [production-checklist](reference/production-checklist.md) |
