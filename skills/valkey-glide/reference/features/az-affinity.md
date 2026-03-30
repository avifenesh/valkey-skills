# Availability Zone Affinity Routing

Use when running in a multi-AZ cloud deployment and you want to reduce read latency and cross-AZ data transfer costs by routing reads to same-zone replicas.

Requires: Valkey 8.0+ (for the `availability-zone` server configuration directive).

AZ Affinity is a read routing strategy that directs read operations to replicas in the same availability zone as the client. This reduces cross-AZ network latency (by ~500us) and avoids cross-AZ data transfer charges.

## ReadFrom Strategies

| Strategy | Python | Java | Node.js | Go | Behavior |
|----------|--------|------|---------|----|----------|
| Primary only | `ReadFrom.PRIMARY` | `ReadFrom.PRIMARY` | `"primary"` | `config.Primary` | All reads go to the primary (default) |
| Prefer replica | `ReadFrom.PREFER_REPLICA` | `ReadFrom.PREFER_REPLICA` | `"preferReplica"` | `config.PreferReplica` | Round-robin across replicas, fallback to primary |
| AZ affinity | `ReadFrom.AZ_AFFINITY` | `ReadFrom.AZ_AFFINITY` | `"AZAffinity"` | `config.AzAffinity` | Prefer replicas in the client's AZ |
| AZ affinity + primary | `ReadFrom.AZ_AFFINITY_REPLICAS_AND_PRIMARY` | `ReadFrom.AZ_AFFINITY_REPLICAS_AND_PRIMARY` | `"AZAffinityReplicasAndPrimary"` | `config.AzAffinityReplicaAndPrimary` | Local replicas, then local primary, then remote |

### AZ_AFFINITY

Routes read requests to replicas in the same AZ as the client in a round-robin manner. Falls back to other replicas or the primary if no local replicas are available.

### AZ_AFFINITY_REPLICAS_AND_PRIMARY

Routes read requests to any node within the client's AZ (replicas first, then primary) in a round-robin manner. Falls back to any remote replica or primary if no local nodes are available. This is useful when read load exceeds what local replicas can handle alone.

## Setup

### Step 1: Configure Server Nodes

Each Valkey node must be configured with its availability zone. This can be done via the `availability-zone` configuration directive:

```bash
# In valkey.conf
availability-zone us-east-1a
```

Or at runtime:

```python
await client.config_set(
    {"availability-zone": "us-east-1a"},
    route=ByAddressRoute(host="node1.example.com", port=6379)
)
```

### Step 2: Configure the Client

#### Python

```python
from glide import (
    GlideClusterClient,
    GlideClusterClientConfiguration,
    NodeAddress,
    ReadFrom,
)

config = GlideClusterClientConfiguration(
    addresses=[
        NodeAddress("node1.example.com", 6379),
        NodeAddress("node2.example.com", 6380),
    ],
    read_from=ReadFrom.AZ_AFFINITY,
    client_az="us-east-1a",
)
client = await GlideClusterClient.create(config)
```

Both `AZ_AFFINITY` and `AZ_AFFINITY_REPLICAS_AND_PRIMARY` require `client_az` to be set. The client validates this at construction time:

```python
# This raises ValueError
config = GlideClusterClientConfiguration(
    addresses=[...],
    read_from=ReadFrom.AZ_AFFINITY,
    # client_az not set - ValueError!
)
```

#### Java

```java
import glide.api.GlideClusterClient;
import glide.api.models.configuration.GlideClusterClientConfiguration;
import glide.api.models.configuration.NodeAddress;
import glide.api.models.configuration.ReadFrom;

GlideClusterClientConfiguration config = GlideClusterClientConfiguration.builder()
    .address(NodeAddress.builder().host("node1.example.com").port(6379).build())
    .address(NodeAddress.builder().host("node2.example.com").port(6380).build())
    .readFrom(ReadFrom.AZ_AFFINITY)
    .clientAz("us-east-1a")
    .build();

GlideClusterClient client = GlideClusterClient.createClient(config).get();
```

#### Node.js

```javascript
import { GlideClusterClient } from "@valkey/valkey-glide";

const client = await GlideClusterClient.createClient({
    addresses: [
        { host: "node1.example.com", port: 6379 },
        { host: "node2.example.com", port: 6380 },
    ],
    readFrom: "AZAffinity",
    clientAz: "us-east-1a",
});
```

#### Go

```go
import (
    glide "github.com/valkey-io/valkey-glide/go/v2"
    "github.com/valkey-io/valkey-glide/go/v2/config"
)

cfg := config.NewClusterClientConfiguration().
    WithAddress(&config.NodeAddress{Host: "node1.example.com", Port: 6379}).
    WithAddress(&config.NodeAddress{Host: "node2.example.com", Port: 6380}).
    WithReadFrom(config.AzAffinity).
    WithClientAZ("us-east-1a")

client, err := glide.NewClusterClient(cfg)
```

## Cost Savings

### AWS Cross-AZ Pricing

AWS charges $0.01/GB for cross-AZ data transfer in each direction ($0.02/GB round-trip) within the same region. For high-throughput Valkey workloads doing millions of reads per second, this adds up significantly. A typical deployment with 3 AZs sending 80% read traffic can reduce cross-AZ data transfer costs by roughly 60-70% by using AZ Affinity.

### Concrete Example

For a read-heavy workload at 250 MB/s:

| Metric | Without AZ Affinity | With AZ Affinity |
|--------|--------------------|--------------------|
| Read traffic | 250 MB/s | 250 MB/s |
| Cross-AZ reads | ~75% (3 of 4 AZs) | ~0% (reads from local AZ) |
| Monthly cross-AZ transfer | ~486 TB | ~121 TB |
| Monthly cost | ~$4,373 | ~$1,088 |
| **Monthly savings** | - | **~$3,285** |

Actual savings depend on cluster topology, replica placement, and read/write ratio. The savings scale linearly with read throughput.

### GCP and Other Clouds

The same `clientAz` parameter works with GCP zone names (e.g., `us-central1-a`). Cross-zone pricing varies by cloud provider but the latency reduction benefit applies universally.

## Standalone Mode

AZ Affinity also works in standalone mode with replicas. Configure `client_az` in the `GlideClientConfiguration` and set the appropriate `ReadFrom` strategy:

```python
config = GlideClientConfiguration(
    addresses=[
        NodeAddress("primary.example.com", 6379),
        NodeAddress("replica1.example.com", 6380),
    ],
    read_from=ReadFrom.AZ_AFFINITY,
    client_az="us-east-1a",
)
```

## How It Works

1. GLIDE connects to the cluster and discovers topology
2. Each node's AZ is read from the server's `availability-zone` config
3. When a read command is issued, the client checks the `ReadFrom` strategy
4. For `AZ_AFFINITY`, the client filters replicas to those matching `client_az` and round-robins among them
5. If no local AZ replicas exist, the client falls back to other replicas, then the primary
6. Topology refreshes update the AZ mapping automatically

## Latency Impact

AZ Affinity typically reduces read latency by ~500 microseconds by avoiding cross-AZ network hops. The exact improvement depends on cloud provider, region, and network conditions.

In-AZ latency is typically 0.1-0.3ms, while cross-AZ latency is 0.5-1.0ms. For workloads dominated by small-value reads, this represents a significant relative improvement.

## Related Features

- [Scripting](scripting.md) - read-only functions (`fcall_ro`) are routed to same-zone replicas when using AZ Affinity
- [OpenTelemetry](opentelemetry.md) - OTel latency metrics help measure the impact of AZ-affinity routing
- [TLS and Authentication](tls-auth.md) - AZ Affinity is commonly combined with TLS in cloud deployments
