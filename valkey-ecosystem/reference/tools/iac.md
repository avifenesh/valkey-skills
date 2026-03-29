# Infrastructure as Code

Use when provisioning Valkey infrastructure with Terraform or deploying to Kubernetes with Helm charts.

---

## Terraform

Terraform support for Valkey is available across multiple cloud providers, either through managed service resources or community modules.

### AWS ElastiCache for Valkey

The `terraform-provider-aws` supports ElastiCache for Valkey natively. Use `aws_elasticache_replication_group` or `aws_elasticache_serverless_cache` with the Valkey engine.

```hcl
resource "aws_elasticache_replication_group" "valkey" {
  replication_group_id = "valkey-cluster"
  description          = "Valkey replication group"
  engine               = "valkey"
  engine_version       = "8.0"
  node_type            = "cache.r7g.large"
  num_cache_clusters   = 3

  automatic_failover_enabled = true
  multi_az_enabled           = true

  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
}
```

For serverless:

```hcl
resource "aws_elasticache_serverless_cache" "valkey" {
  engine = "valkey"
  name   = "valkey-serverless"

  cache_usage_limits {
    data_storage {
      maximum = 10
      unit    = "GB"
    }
    ecpu_per_second {
      maximum = 5000
    }
  }
}
```

### AWS MemoryDB for Valkey

Use `terraform-aws-modules/memory-db/aws` for a higher-level module that provisions MemoryDB with sensible defaults:

```hcl
module "memory_db" {
  source  = "terraform-aws-modules/memory-db/aws"
  version = "~> 1.0"

  name        = "valkey-memorydb"
  engine      = "valkey"
  node_type   = "db.r7g.large"
  num_shards  = 2
  num_replicas_per_shard = 1
}
```

MemoryDB provides durable in-memory storage with a transaction log - suitable for primary data store use cases.

### Azure

Azure does not offer a managed Valkey service directly. For self-hosted Valkey on Azure, use the Azure Verified Modules to provision AKS clusters, then deploy Valkey via Helm:

```hcl
module "aks" {
  source  = "Azure/aks/azurerm"
  # AKS configuration...
}

resource "helm_release" "valkey" {
  name       = "valkey"
  repository = "oci://registry-1.docker.io/valkeycharts"
  chart      = "valkey"
  namespace  = "valkey"

  set {
    name  = "architecture"
    value = "replication"
  }
}
```

### Exoscale

The Exoscale Terraform provider has native Valkey DBaaS support:

```hcl
resource "exoscale_dbaas_service" "valkey" {
  name = "my-valkey"
  type = "valkey"
  plan = "startup-4"
  zone = "ch-gva-2"
}
```

### Yandex Cloud

Yandex Cloud provides a Managed Service for Valkey via the `yandex_mdb_redis_cluster` resource in the Yandex Terraform provider with the Valkey engine selected. The resource name retains "redis" because the Yandex provider uses the Redis resource type with a Valkey engine option rather than a dedicated Valkey resource. Supports version selection, resource presets, disk configuration, and multi-zone host placement.

### Provider Summary

| Provider | Resource Type | Managed Service |
|----------|--------------|-----------------|
| AWS | `aws_elasticache_replication_group` | ElastiCache for Valkey |
| AWS | `aws_elasticache_serverless_cache` | ElastiCache Serverless |
| AWS | `terraform-aws-modules/memory-db/aws` | MemoryDB for Valkey |
| Azure | AKS + Helm | Self-hosted on Kubernetes |
| Exoscale | `exoscale_dbaas_service` | DBaaS Valkey |
| Yandex | `yandex_mdb_redis_cluster` (Valkey engine) | Managed Service |

---

## Helm Charts

### Official Valkey Helm Chart (Recommended)

The project-maintained Helm chart is the recommended deployment method for Valkey on Kubernetes.

- **Latest version**: valkey-0.9.3 (2026-01-15)
- **Registry**: `oci://registry-1.docker.io/valkeycharts/valkey`
- **Source**: [valkey-io/valkey-helm](https://github.com/valkey-io/valkey-helm) (239 stars)
- **Install repo**: `helm repo add valkey https://valkey.io/valkey-helm/`
- **Slack**: #Valkey-helm channel

```bash
# Install standalone
helm install valkey oci://registry-1.docker.io/valkeycharts/valkey

# Install with primary-replica topology
helm install valkey oci://registry-1.docker.io/valkeycharts/valkey \
  --set architecture=replication \
  --set replica.replicaCount=3
```

#### Supported Topologies

**Standalone** (`architecture: standalone`) - Single instance. Suitable for development or caching where data loss is acceptable.

**Primary-Replica** (`architecture: replication`) - One primary with configurable replica count. Provides read scaling and basic HA. Combine with Sentinel for automatic failover.

#### Common Values

| Key | Purpose |
|-----|---------|
| `auth.enabled` / `auth.password` | Authentication |
| `primary.persistence.enabled` / `primary.persistence.size` | RDB/AOF persistence |
| `primary.resources.requests` / `primary.resources.limits` | CPU and memory bounds |
| `metrics.enabled` / `metrics.serviceMonitor.enabled` | Prometheus metrics export |

### Bitnami Charts

Bitnami offers `valkey` and `valkey-cluster` Helm charts. However, since August 2025, Bitnami charts require a commercial subscription for production use.

- Use the official Valkey Helm chart for new deployments
- Existing Bitnami users should evaluate migration to the official chart

The Bitnami charts offer more configuration options and battle-tested defaults, but the subscription requirement makes the official chart the better default choice.

### Percona Valkey Helm Chart

Percona maintains a separate Helm chart for Valkey deployment
(EvgeniyPatlan/percona-valkey-helm, updated 2026-03-05). This chart integrates
with Percona's monitoring approach and is an alternative for teams already using
Percona products.

### Terraform Module Gaps

No dedicated, well-maintained Terraform modules exist for self-hosted Valkey.
CloudPosse's `terraform-aws-elasticache-redis` (147 stars) works with Valkey
since AWS ElastiCache supports Valkey as an engine, but module naming and docs
are Redis-centric. For self-hosted deployments, use Terraform's Helm provider
with the official Valkey Helm chart.

### Chart Selection Guide

| Scenario | Chart |
|----------|-------|
| New deployment | Official Valkey chart |
| Development/testing | Official Valkey chart (standalone) |
| Production HA | Official Valkey chart (replication) + Sentinel |
| Percona ecosystem | Percona Valkey Helm chart |
| Existing Bitnami user | Continue if subscribed, otherwise migrate |

For Kubernetes monitoring, deploy redis_exporter as a sidecar and configure PodMonitor or ServiceMonitor CRDs. See the **valkey-ops** skill for operational details.

---

## See Also

- [CLI and Benchmarking Tools](cli-benchmarking.md) - valkey-cli for verifying deployed instances
- [Testing Tools](testing.md) - Testcontainers for local development and CI
- [Migration from Redis](migration.md) - migrating existing Redis infrastructure to Valkey
