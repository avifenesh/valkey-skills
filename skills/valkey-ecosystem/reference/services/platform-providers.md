# Platform Providers for Managed Valkey

Use when evaluating non-hyperscaler managed Valkey services, comparing platform providers, or choosing a provider for multi-cloud, PaaS, budget, or compliance-driven deployments.

---

## Overview

Beyond AWS and Google Cloud, several platform providers offer managed Valkey services. These range from full-featured multi-cloud platforms to focused regional providers. Each targets a different segment - multi-cloud flexibility, developer simplicity, compliance requirements, or cost efficiency.

---

## Aiven for Valkey

### Profile

Aiven is a multi-cloud data platform that operates managed services across AWS, GCP, and Azure. Their Valkey offering supports multiple versions and includes a free tier.

### Key Details

| Property | Value |
|----------|-------|
| Versions | 7.2, 8.x, 9.0 |
| Clouds | AWS, GCP, Azure |
| Plans | Free, Developer, Hobbyist, Startup, Business, Premium |
| Free plan | 1 node, 1 CPU, 1 GB RAM, maxmemory 50%, no time limit |
| Free trial | $300 credit for 30 days on any plan |
| Backups | Automatic 24-hour backups |
| Deployment | Single-node and HA configurations |

### Strengths

- **Multi-cloud**: Deploy Valkey on whichever cloud your application runs on, or migrate between clouds without changing the managed service provider
- **Multi-version support**: Offers Valkey 7.2 through 9.0, so you can match versions to your compatibility needs
- **Unified platform**: Manage Valkey alongside PostgreSQL, Kafka, OpenSearch, and other services from one console
- **Free tier**: Permanent free plan (1 node, 1 GB) plus $300 trial credit for larger plans
- **Terraform provider**: `aiven/aiven` Terraform provider for infrastructure-as-code
- **Kubernetes operator**: Integration available for K8s-native deployments

### Considerations

- Pricing is higher than hyperscaler-native services for equivalent capacity
- Performance depends on the underlying cloud - no proprietary optimizations beyond standard VM tuning

---

## DigitalOcean Managed Valkey

### Profile

DigitalOcean replaced its Managed Redis offering with Managed Valkey, positioning it as the default in-memory data store on the platform.

### Key Details

| Property | Value |
|----------|-------|
| Versions | 7.2+ |
| Starting price | $15/month (single node) |
| HA starting price | $30/month (primary + replica) |
| Regions | 14 (NYC1-3, AMS3, SFO2-3, SGP1, LON1, FRA1, TOR1, BLR1, SYD1, ATL1, RIC1) |
| Features | Cluster support, standby nodes, auto updates, eviction policies, TLS |

### Strengths

- **Low entry cost**: $15/month makes it accessible for small projects and startups
- **Simple pricing**: Predictable monthly cost without complex per-request billing
- **Integrated platform**: Works naturally with DigitalOcean Droplets, App Platform, and Kubernetes
- **Managed HA**: High availability with automatic failover from $30/month

### Considerations

- Fewer regions than hyperscalers
- No serverless option
- Limited advanced features compared to ElastiCache or Memorystore

---

## Heroku Key-Value Store

### Profile

Heroku's Key-Value Store is built on Valkey 8.x, replacing their previous Redis add-on. It integrates tightly with the Heroku PaaS experience.

### Key Details

| Property | Value |
|----------|-------|
| Engine | Valkey 8.x |
| Modules | JSON and Bloom included |
| Compliance | HIPAA-compliant via Shield plan |
| Features | Performance analytics dashboard |

### Strengths

- **PaaS integration**: Zero infrastructure management - provision via `heroku addons:create`
- **Modules included**: valkey-json and valkey-bloom available out of the box
- **HIPAA compliance**: Shield plan meets healthcare compliance requirements
- **Performance analytics**: Built-in dashboard for monitoring key metrics
- **Developer experience**: Fastest path from zero to running Valkey for Heroku users

### Considerations

- Only available within the Heroku ecosystem
- Pricing follows Heroku's add-on model, which can be expensive at scale
- Limited version selection compared to providers like Aiven

---

## Percona for Valkey

### Profile

Percona offers Valkey as a fully managed service through Percona Ivee, alongside enterprise support, consulting, and migration services.

### Key Details

| Property | Value |
|----------|-------|
| Type | Managed service (Percona Ivee), support, and consulting |
| Versions | All |
| Key person | Kyle Davis - Valkey General Manager at Percona |
| Services | Managed Valkey (Ivee), enterprise support, migration planning, performance tuning |
| Monitoring | Percona Monitoring and Management (PMM) supports Valkey |

### Strengths

- **Managed service**: Percona Ivee provides fully managed Valkey with automated operations
- **Expert support**: Deep database expertise applied to Valkey operations
- **Migration services**: Professional guidance for Redis-to-Valkey migrations
- **PMM integration**: Percona Monitoring and Management provides Valkey dashboards
- **Vendor-neutral**: Works with your choice of infrastructure

### Considerations

- You manage the infrastructure yourself - Percona advises but does not host
- Support contracts are priced for enterprise budgets

---

## UpCloud Managed Valkey

### Profile

UpCloud is a European cloud provider offering managed Valkey as part of their GDPR-compliant infrastructure.

### Key Details

| Property | Value |
|----------|-------|
| Compliance | GDPR-compliant, EU data residency |
| Data centers | 13 across 4 continents |
| SLA | 100% |
| Type | Managed database service |

### Strengths

- **GDPR compliance**: Data stays within EU jurisdictions with full GDPR compliance
- **EU data residency**: Guaranteed European data storage for regulatory requirements
- **European provider**: No US CLOUD Act exposure for EU-sensitive workloads

### Considerations

- Smaller provider with fewer features than hyperscaler offerings
- Limited geographic reach outside Europe
- Less community documentation and ecosystem integration

---

## Exoscale DBaaS Valkey

### Profile

Exoscale is a European cloud provider offering Valkey as part of their Database-as-a-Service platform.

### Key Details

| Property | Value |
|----------|-------|
| Deployment | DBaaS (Database as a Service) |
| IaC | Terraform provider support |
| Region | European data centers |

### Strengths

- **Terraform support**: Native Terraform provider for automated deployments
- **European infrastructure**: EU-based data centers
- **Simple DBaaS model**: Managed database without complex configuration

### Considerations

- Limited version information publicly available
- Smaller ecosystem compared to major providers

---

## Vultr Managed Databases

### Profile

Vultr offers Valkey as part of their managed database platform alongside PostgreSQL, MySQL, and Kafka. Vultr is not currently listed on the Valkey participants page.

### Key Details

| Property | Value |
|----------|-------|
| Type | Managed database service |
| Status | Available (relatively new) |
| Other DBs | PostgreSQL, MySQL, Apache Kafka |

### Strengths

- **Simple infrastructure**: Part of Vultr's developer-friendly cloud platform
- **Competitive pricing**: Vultr is known for cost-effective compute

### Considerations

- Documentation is still being built out
- Feature depth unclear compared to more established providers

---

## Momento

### Profile

Momento offers a Valkey-compatible managed cache service focused on zero-operations and global resilience.

### Key Details

| Property | Value |
|----------|-------|
| Type | Managed serverless cache |
| Notable customers | Snap Inc, FOX, Coinbase |

### Strengths

- **Zero-operations**: No infrastructure management at all
- **Globally resilient**: Designed for multi-region workloads
- **Enterprise adoption**: Used by large consumer-facing companies

---

## NetApp Instaclustr

### Profile

NetApp Instaclustr for Valkey provides enterprise-grade managed platform features with 24x7 support.

### Key Details

| Property | Value |
|----------|-------|
| Type | Managed platform |
| Support | 24x7 enterprise support |

---

## Oracle OCI Cache

### Profile

Oracle Cloud Infrastructure (OCI) Cache is a Valkey-based managed service offering sub-millisecond latency.

### Key Details

| Property | Value |
|----------|-------|
| Type | Managed in-memory cache |
| Platform | Oracle Cloud Infrastructure |

---

## anynines (a9s KeyValue)

### Profile

anynines offers a managed in-memory NoSQL database built on Valkey, available on both Cloud Foundry and Kubernetes.

### Key Details

| Property | Value |
|----------|-------|
| Type | Managed in-memory database |
| Platforms | Cloud Foundry, Kubernetes |

---

## BetterDB (Monitoring)

### Profile

BetterDB is the first monitoring platform built specifically for Valkey. It is not a hosting provider.

### Key Details

| Property | Value |
|----------|-------|
| Type | Monitoring platform (not hosting) |
| Features | COMMANDLOG, per-slot metrics, async I/O threading visibility |
| Integration | Prometheus |

---

## Notable Absences

Two significant providers do not offer managed Valkey:

### Upstash

Upstash remains Redis-only as of early 2026. Their serverless, per-request pricing model is popular for edge and serverless applications, but they have not adopted Valkey. They are not listed on the Valkey participants page. If you need serverless pay-per-request Valkey, AWS ElastiCache Serverless is currently the only option.

### Azure (Microsoft)

Microsoft has not announced Valkey support for Azure Cache. Azure maintains "Azure Managed Redis" using Redis Ltd's software, supporting only Redis OSS (4.0.x, 6.0.x) and Redis Enterprise. This makes Azure the notable holdout among major cloud providers. Multi-cloud strategies involving Azure require either self-hosted Valkey on Azure VMs/AKS or a third-party provider like Aiven that deploys on Azure infrastructure.

---

## Provider Comparison at a Glance

| Provider | Multi-Cloud | Free Tier | Modules | Compliance | IaC |
|----------|-------------|-----------|---------|------------|-----|
| Aiven | Yes (AWS/GCP/Azure) | Yes | Standard | SOC 2 | Terraform |
| DigitalOcean | No | No | Standard | SOC 2 | Terraform |
| Heroku | No | No | JSON + Bloom | HIPAA (Shield) | CLI/API |
| Percona (Ivee) | No | No | Standard | Enterprise | Terraform |
| UpCloud | No | No | Standard | GDPR | API |
| Exoscale | No | No | Standard | EU | Terraform |
| Vultr | No | No | Standard | - | API |
| Momento | No | - | Compatible | - | SDK |
| NetApp Instaclustr | No | No | Standard | Enterprise | - |
| Oracle OCI | No | No | Standard | Enterprise | Terraform |
| anynines | No | No | Standard | - | - |

---

## Pricing Notes

All pricing figures reflect publicly available information at the time of writing. Platform provider pricing changes frequently - consult each provider's current pricing page before making decisions. DigitalOcean's $15/month and $30/month figures are starting prices for the smallest available tiers.

---

## See Also

- [Managed Service Comparison](comparison.md) - cross-provider feature and pricing comparison
- [Monitoring Platforms](../monitoring/platforms.md) - Percona PMM, Datadog, and New Relic for observability
