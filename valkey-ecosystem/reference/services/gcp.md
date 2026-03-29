# Google Cloud Memorystore for Valkey

Use when evaluating or deploying Valkey on Google Cloud, planning vector search workloads, or comparing GCP managed Valkey with other providers.

---

## Overview

Google Cloud Memorystore for Valkey is a fully managed, in-memory key-value service. Google was an early contributor to the Valkey project - notably contributing the vector search module - and Memorystore reflects that investment with features like built-in vector search and support for the latest Valkey versions.

---

## Supported Versions

| Version | Status | Notes |
|---------|--------|-------|
| Valkey 7.2 | GA | Compatible with Redis OSS 7.2 workloads |
| Valkey 8.0 | GA | Hash field expiration, performance improvements |
| Valkey 9.0 | GA | Latest; 1B+ RPS clusters, atomic slot migration |

Memorystore supports Valkey 9.0 - the newest major release - making it one of the first managed services to offer it.

---

## Architecture

### Cluster Topology

- **1 to 250 nodes** per instance
- Nodes distributed across zones within a region
- Automatic shard management and slot balancing
- Online resharding without downtime

### High Availability

- **99.99% SLA** - one of the highest availability guarantees for managed Valkey
- Automatic failover with replica promotion
- Multi-zone replication within a region
- Health monitoring and self-healing

### Cross-Region Replication

Memorystore supports cross-region replication for disaster recovery and geo-distributed read access. This enables active-passive setups where a secondary region can take over if the primary region fails, or active-read configurations that serve reads from the nearest region.

---

## Built-In Vector Search

Memorystore includes the valkey-search module natively, enabling vector similarity search without additional module management.

### Capabilities

- **KNN** (exact) and **HNSW** (approximate) nearest-neighbor algorithms
- Single-digit millisecond latency at 99%+ recall
- Indexes on Hash and JSON data types
- Hybrid queries combining vector search with numeric and tag filters
- Scales to billions of vectors across the cluster

### Use Cases

- Semantic search and retrieval-augmented generation (RAG)
- Recommendation engines
- Image and audio similarity
- Anomaly detection
- Real-time personalization

Google was one of the earliest cloud providers to include vector search natively in their managed Valkey offering. AWS ElastiCache has since added built-in vector search as well.

---

## Pricing

### Commitment Discounts

| Commitment | Savings vs On-Demand |
|------------|---------------------|
| On-demand | Baseline |
| 1-year commit | 20% savings |
| 3-year commit | 40% savings |

### Pricing Model

Memorystore bills based on:

- **Node capacity** (GB-hours of provisioned memory)
- **Network egress** (cross-region and internet)
- Commitment discounts apply to the capacity charges

There is no serverless/pay-per-request option like AWS ElastiCache Serverless. You provision a fixed cluster size and pay for that capacity whether utilized or not. This favors steady-state workloads with predictable capacity needs.

### Cost Optimization

- Right-size nodes based on actual memory utilization
- Use commitment discounts for production workloads with known retention periods
- Leverage cross-region replication selectively - only for workloads that need it
- Monitor the memory utilization ratio to avoid over-provisioning

---

## When to Choose Memorystore

### Strong Fit

- **Already on GCP**: Lowest latency and simplest networking when your application runs on GCP
- **Vector search workloads**: Built-in vector search eliminates module management overhead
- **High availability requirements**: 99.99% SLA is among the strongest available
- **Large clusters**: Scaling to 250 nodes covers most workloads without architectural workarounds
- **Valkey 9.0 features**: Early access to the latest Valkey capabilities
- **Predictable workloads**: Commitment discounts reward stable capacity needs

### Weaker Fit

- **Variable/spiky workloads**: No serverless option means you pay for peak capacity at all times
- **Multi-cloud strategy**: Locks you into GCP networking and IAM
- **Budget-constrained small workloads**: Minimum cluster size may exceed needs for small projects

---

## Integration with GCP Services

- **VPC networking**: Private Service Access for secure connectivity
- **IAM**: GCP IAM for access control alongside Valkey ACLs
- **Cloud Monitoring**: Native metrics in Cloud Monitoring dashboards
- **Terraform**: `google_redis_cluster` resource in the Google provider (the resource name uses "redis" for historical reasons but supports Valkey engine)

---

## Migration

### From Self-Hosted Valkey or Redis OSS

1. Create a Memorystore instance with the target Valkey version
2. Use RDB import or set up replication from the source
3. Cut over application endpoints once sync completes

### From Memorystore for Redis

Google provides an in-place migration path from Memorystore for Redis to Memorystore for Valkey. Check current documentation for version compatibility constraints.

---

## Pricing Notes

All savings percentages reflect publicly available commitment discount rates. Actual costs depend on region, node configuration, network usage, and commitment terms. Consult the current GCP Memorystore pricing page before making capacity decisions.

---

## See Also

- [Managed Service Comparison](comparison.md) - cross-provider feature and pricing comparison
- [Prometheus and Grafana](../monitoring/prometheus-grafana.md) - metrics collection and dashboards for GCP-hosted Valkey
- [Monitoring Platforms](../monitoring/platforms.md) - Datadog, New Relic, and Percona PMM integrations
