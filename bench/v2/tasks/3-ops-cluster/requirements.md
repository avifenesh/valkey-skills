# Production Valkey Cluster on Kubernetes using Valkey Operator

Deploy a production-ready Valkey cluster on a local Kubernetes cluster (kind) using the Valkey ecosystem's Kubernetes operator.

## Requirements

### Operator-based deployment
- Use the Valkey Kubernetes Operator (or Bitnami Helm chart for Valkey) - NOT hand-crafted StatefulSets
- If no official Valkey operator exists yet, use the closest ecosystem tool and document your choice

### Cluster Topology
- 3 primary nodes, 3 replica nodes
- Cluster mode enabled

### Security
- ACL with 3 users:
  - `admin` - full access (all commands, all keys)
  - `app` - read/write access (data commands only, no admin)
  - `monitor` - read-only access (INFO, CLUSTER INFO, CLIENT LIST)
- Default user disabled
- TLS between all nodes (self-signed certs are fine for this test)

### Modules
- valkey-search module loaded
- Verify with a test that creates a vector search index

### High Availability
- PodDisruptionBudget (at least 2 primaries available)
- Anti-affinity rules (primaries spread across nodes)
- Readiness and liveness probes

### Storage
- Persistent volume claims for data
- AOF enabled

### Monitoring
- Prometheus metrics exporter sidecar
- Service for scraping metrics

### Deliverables
1. Operator installation manifests or Helm values
2. Custom resource definition for the Valkey cluster
3. A script to create the kind cluster and deploy everything
4. A test script that:
   - Connects as the `app` user
   - Writes data
   - Creates a search index with a vector field
   - Runs a vector search query
   - Verifies ACL restrictions (monitor user cannot write)
