# AWS Managed Valkey Services

Use when choosing between ElastiCache and MemoryDB for Valkey on AWS, estimating costs, or planning AWS Valkey deployments.

---

## Overview

AWS offers two distinct managed Valkey services. ElastiCache for Valkey is the general-purpose cache and data store. MemoryDB for Valkey adds durability via a transaction log for workloads that cannot tolerate data loss.

---

## ElastiCache for Valkey

### Deployment Models

ElastiCache provides two deployment options with different operational characteristics:

| Model | Scaling | Provisioning | Billing |
|-------|---------|--------------|---------|
| **Serverless** | Automatic; scales on demand | No node selection | Pay per ECPU + GB-hr storage |
| **Node-based** | Manual; choose instance type and count | Select node family and size | Pay per node-hour |

**Serverless** is suited for variable or unpredictable workloads, development environments, and teams that prefer minimal infrastructure management. It eliminates capacity planning entirely.

**Node-based** is better for steady-state production workloads where you can predict capacity. It provides more control over instance placement, network performance, and cost optimization through Reserved Instances.

### Supported Versions

- Valkey 7.2
- Valkey 8.x

Check AWS documentation for current version support - additional versions (including 9.0) may be available. ElastiCache previously supported Redis OSS and Memcached engines. Valkey is now the recommended engine for new deployments.

### Key Features

- **Multi-AZ replication** with automatic failover
- **Cluster mode** for horizontal scaling across shards
- **Encryption** at rest and in transit (TLS)
- **IAM authentication** and Valkey ACLs
- **Automatic backups** with point-in-time recovery
- **Online resharding** without downtime
- **Global Datastore** for cross-region replication

### GLIDE AZ-Affinity Integration

Valkey GLIDE supports AZ-affinity routing on ElastiCache, directing reads to replicas in the same Availability Zone as the client. This reduces cross-AZ data transfer costs and latency. The client auto-discovers AZ topology from the cluster - no manual configuration of AZ mappings is needed.

To enable AZ-affinity, configure the GLIDE client with the `ReadFrom.AZ_AFFINITY` strategy. The client will prefer replicas in its own AZ for read commands, falling back to other AZs only when no local replica is available. This is particularly impactful in multi-AZ clusters where cross-AZ data transfer charges accumulate.

### Built-In Module Support

ElastiCache includes JSON and vector search as built-in features - no manual module loading required:

- **JSON**: Supported natively for Valkey 7.2+ (AWS versioning)
- **Vector search**: Built-in HNSW and FLAT algorithms, cosine/Euclidean/inner product metrics, hybrid search with tag and numeric filters
- AWS claims "lowest latency vector search with highest throughput and best price-performance at 95%+ recall rate among popular vector databases on AWS"

### AWS Pricing (Valkey vs Redis Engine)

These are AWS ElastiCache pricing differences between the Valkey and Redis OSS engine options. They reflect AWS's pricing decisions, not inherent cost differences between the software.

- **Serverless**: 33% lower price than ElastiCache Serverless for Redis OSS, starting at $6/month
- **Serverless minimum**: 100 MB per cache (vs 1 GB for Redis OSS/Memcached)
- **Node-based**: 20% lower price than other node-based ElastiCache engines
- **Data tiering**: Available on Graviton2-based R6gd nodes (Valkey 7.2+)

Pricing is subject to change - check the AWS pricing page for current rates.

### Free Tier

- $100 credits for post-July 2025 signups
- 750 hours cache.t3.micro for pre-July 2025 accounts

---

## MemoryDB for Valkey

### What Makes It Different

MemoryDB is not a cache - it is a durable in-memory database. The critical distinction from ElastiCache:

| Property | ElastiCache | MemoryDB |
|----------|-------------|----------|
| Durability | Best-effort; data may be lost on failover | Durable; transaction log persists every write |
| Recovery | Restores from backup (potential data gap) | Recovers to last committed transaction |
| Write latency | Sub-millisecond | Single-digit milliseconds (log write adds latency) |
| Read latency | Sub-millisecond | Sub-millisecond |
| Primary use | Cache, session store, ephemeral data | Primary database, system of record |

### Transaction Log

MemoryDB maintains a distributed, durable transaction log that records every write operation. On node failure, the replacement node replays the log to reconstruct the exact dataset. This eliminates the data-loss window that exists with snapshot-based recovery.

The transaction log adds write latency (single-digit milliseconds vs sub-millisecond for ElastiCache) but guarantees that acknowledged writes survive infrastructure failures.

### Multi-AZ Architecture

MemoryDB replicates data across multiple Availability Zones automatically. Failover promotes a replica with access to the full transaction log, ensuring no acknowledged write is lost during the promotion.

### Supported Versions

- Valkey 7.2

Check AWS documentation for current MemoryDB version support.

### Key Features

- **11 nines durability** (99.999999999%) for stored data
- **Multi-AZ** with automatic failover
- **Microsecond read latency**, single-digit millisecond write latency
- **Snapshots** for backup and restore
- **Encryption** at rest and in transit
- **IAM authentication** and Valkey ACLs
- **Cluster mode** with online resharding

---

## When to Choose ElastiCache vs MemoryDB

### Choose ElastiCache When

- **Caching**: Database query results, API responses, session data where the source of truth lives elsewhere
- **Low write latency is critical**: Sub-millisecond writes matter more than durability
- **Cost sensitivity**: ElastiCache is generally cheaper for equivalent capacity
- **Variable workloads**: Serverless mode handles traffic spikes without provisioning
- **You have a separate primary database**: Valkey supplements but does not replace your database

### Choose MemoryDB When

- **Valkey is your primary database**: No separate backing store exists
- **Zero data loss on failover**: Financial transactions, order state, inventory counts
- **Compliance requirements**: Audit trails demand durable writes
- **Replacing a traditional database**: Migrating from a disk-based DB to in-memory for performance
- **Event sourcing**: Transaction log aligns naturally with event-sourced architectures

### Common Pattern: Both Together

Many AWS architectures use both services. ElastiCache serves as the hot cache layer for read-heavy workloads (session lookups, API response caching), while MemoryDB backs the durable data layer (user state, transaction records). This combination delivers sub-millisecond reads from ElastiCache with guaranteed durability from MemoryDB - each service handling what it does best.

### Decision Shortcut

If you can regenerate the data from another source, use ElastiCache. If losing even one write is unacceptable, use MemoryDB.

---

## Terraform Support

Both services have mature Terraform support:

- **ElastiCache**: `aws_elasticache_replication_group` resource with `engine = "valkey"`
- **MemoryDB**: `terraform-aws-modules/memory-db/aws` community module supports Valkey
- **Gruntwork**: Published ElastiCache for Valkey module

---

## Migration Path

For existing ElastiCache for Redis or MemoryDB for Redis users:

1. ElastiCache supports in-place engine upgrade from Redis OSS to Valkey
2. MemoryDB requires creating a new cluster with Valkey engine and migrating data via snapshot
3. Client code changes are minimal - typically just endpoint configuration if using RESP-compatible clients

---

## Pricing Notes

All pricing figures in this document reflect publicly announced savings at the time of Valkey launch on AWS. Actual costs depend on region, instance type, reserved capacity commitments, and data transfer. Always consult the current AWS pricing pages for ElastiCache and MemoryDB before making capacity decisions.

---

## See Also

- [Managed Service Comparison](comparison.md) - cross-provider feature and pricing comparison
- [Prometheus and Grafana](../monitoring/prometheus-grafana.md) - metrics collection and dashboards for AWS-hosted Valkey
- [Monitoring Platforms](../monitoring/platforms.md) - Datadog, New Relic, and Percona PMM integrations
