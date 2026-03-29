# Monitoring Platforms

Use when choosing a monitoring platform for Valkey - comparison of self-hosted
and SaaS options, integration details, and decision guidance.

---

## Percona PMM (Percona Monitoring and Management)

Percona PMM is an open-source, self-hosted monitoring platform built on
VictoriaMetrics (Prometheus-compatible) and Grafana. It provides dedicated
Valkey monitoring out of the box.

**How it works**: PMM uses `redis_exporter` under the hood, registered as an
external service. It ships 10 pre-built Valkey/Redis dashboards in the
`percona/grafana-dashboards` repository.

### Setup

```bash
# Register Valkey instance with PMM
pmm-admin add external --service-name=valkey-primary \
  --listen-port=9121 \
  --group=valkey \
  --environment=production
```

### Key dashboards

| Dashboard | Focus |
|-----------|-------|
| Valkey/Redis Overview | Top commands by latency, cumulative R/W rate |
| Valkey Clients | Connected, blocked, evicted clients per service |
| Valkey Memory | Usage percentage, eviction policy, expired/evicted rates |
| Valkey Replication | Replica vs primary offset lag, full/partial resyncs |
| Valkey Command Details | Per-command latency histograms, p99.9 breakdown |
| Valkey Cluster Details | Slot status, cluster state, known nodes |

**Distinguishing feature**: Per-command latency histograms using
`redis_commands_latencies_usec_bucket` - useful for identifying which specific
commands contribute most to tail latency.

**Valkey-specific gaps**: PMM's dashboards use redis_exporter under the hood and
do not surface Valkey-only primitives like COMMANDLOG (8.1+), CLUSTER SLOT-STATS
(8.0+), or per-thread I/O utilization metrics (9.1). These require custom
dashboard panels.

**Percona Valkey Helm Chart**: Percona maintains a separate Helm chart for Valkey
deployment (EvgeniyPatlan/percona-valkey-helm, updated 2026-03-05). Percona also
has a documentation repo (percona/percona-valkey-doc) covering Valkey installation
from Percona packages.

**Best for**: Teams already running Percona products (MySQL, PostgreSQL,
MongoDB) who want unified database monitoring. Free to self-host.

---

## Datadog

Datadog monitors Valkey through its Redis integration. Since Valkey speaks the
RESP protocol and responds to the same INFO command, the Datadog Agent's Redis
check works without modification.

### Setup

Configure the Datadog Agent Redis check to point at Valkey:

```yaml
# /etc/datadog-agent/conf.d/redisdb.d/conf.yaml
instances:
  - host: valkey-host
    port: 6379
    password: secret
    tags:
      - service:valkey
      - env:production
```

### What you get

- 80+ Redis metrics collected automatically
- Built-in Redis dashboards work with Valkey data
- APM traces correlated with Valkey latency
- Log integration for Valkey server logs
- Anomaly detection and forecasting
- Custom alerting with 500+ integration context

**Best for**: Teams already using Datadog who want Valkey monitoring alongside
their full application stack without running additional infrastructure.

---

## New Relic

New Relic monitors Valkey through its Redis APM integration. The New Relic
infrastructure agent detects Valkey endpoints and collects metrics using the
same commands as its Redis integration.

### Setup

Install the New Relic infrastructure agent and enable the Redis integration:

```yaml
# /etc/newrelic-infra/integrations.d/redis-config.yml
integrations:
  - name: nri-redis
    env:
      HOSTNAME: valkey-host
      PORT: 6379
      PASSWORD: secret
    labels:
      environment: production
      service: valkey
```

### What you get

- Key metrics: connected clients, memory, commands/sec, hit rate
- Application-level visibility when using New Relic APM agents
- Distributed tracing shows Valkey call latency in request flows
- Alert policies with NRQL query flexibility

**Best for**: Teams using New Relic for application performance monitoring who
want Valkey visibility integrated into their APM workflow.

---

## VMware Tanzu for Valkey on Kubernetes

VMware Tanzu Application Catalog includes Valkey charts with built-in
monitoring. When deploying Valkey on Kubernetes through Tanzu, monitoring is
part of the managed experience:

- Prometheus metrics export pre-configured
- Grafana dashboards included
- Health checks and readiness probes built in
- Integration with Tanzu Observability (Wavefront)

**Best for**: Enterprise Kubernetes environments already running VMware Tanzu
where standardized monitoring is a requirement.

---

## Self-Hosted vs SaaS Comparison

| Factor | Self-Hosted (Prometheus/Grafana/PMM) | SaaS (Datadog/New Relic) |
|--------|--------------------------------------|--------------------------|
| **Cost** | Infrastructure only; no per-host fees | Per-host/per-metric pricing; scales with fleet |
| **Setup effort** | Moderate - deploy exporter, Prometheus, Grafana | Low - install agent, enable integration |
| **Data retention** | You control; limited by storage | Included; typically 13-15 months |
| **Customization** | Full control over dashboards and alerts | Template-driven; custom queries available |
| **Maintenance** | You manage upgrades, scaling, HA | Vendor-managed |
| **Data locality** | On-premises; no data leaves your network | Cloud-hosted; check compliance requirements |
| **Correlation** | Valkey metrics only (unless you add more exporters) | Full-stack: APM, infra, logs, traces together |
| **Alerting** | Alertmanager (powerful but manual config) | Built-in with PagerDuty/Slack/etc. integrations |

### Decision guide

Choose **Prometheus + Grafana** when:
- You need full control over metric storage and retention
- Data must stay on-premises (compliance, regulatory)
- You already run Prometheus for other services
- Cost predictability matters (no per-host fees)

Choose **Percona PMM** when:
- You run multiple database types (MySQL, PostgreSQL, MongoDB, Valkey)
- You want pre-built, database-specific dashboards without building them
- Self-hosted is fine but you want less dashboard configuration work

Choose **Datadog or New Relic** when:
- You want Valkey monitoring alongside full application observability
- Minimal operational overhead matters more than per-host cost
- You need APM traces correlated with Valkey latency
- Your team is already on one of these platforms

---

## See Also

- [Prometheus and Grafana](prometheus-grafana.md) - detailed exporter setup, scrape config, dashboards
- [GUI Tools](gui-tools.md) - desktop and web tools for direct Valkey interaction
- Cross-reference the valkey-ops skill for server-side monitoring (INFO, COMMANDLOG, LATENCY, MEMORY DOCTOR)
