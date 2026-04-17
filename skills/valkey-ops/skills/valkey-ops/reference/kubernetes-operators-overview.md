# Valkey Kubernetes Operators - Picking One

Use when deciding between the three Valkey-aware operators.

## Feature matrix

| | Official (`valkey-io/valkey-operator`) | Hyperspike (`hyperspike/valkey-operator`) | SAP (`sap/valkey-operator`) |
|---|---|---|---|
| API | `valkey.io/v1alpha1` | `hyperspike.io/v1` | `cache.cs.sap.com/v1alpha1` |
| Modes | cluster only | standalone / Sentinel / cluster | Sentinel / static primary |
| CRD | `ValkeyCluster` | `Valkey` (short: `vk`) | `Valkey` |
| TLS | **not yet** | cert-manager | cert-manager |
| External access | **not yet** | Envoy proxy or per-shard LB | none |
| OpenShift | not yet | `platformManagedSecurityContext` | no |
| Prometheus | exporter sidecar (default) | ServiceMonitor | ServiceMonitor + PrometheusRule |
| Declarative ACL users | yes (commands/keys/channels/patterns) | no | no |
| Workload type | StatefulSet or Deployment (immutable after creation) | StatefulSet | Bitnami Helm chart |
| Install | `make deploy` from source | Helm or single-YAML | Helm or kubectl |
| Maturity | early (WIP, breaking changes expected) | pre-1.0 community | SAP-maintained |

## Decision points

- **Need TLS or multi-mode today?** Hyperspike or SAP - the official operator has neither yet.
- **Need cluster mode with GitOps-style ACL?** Official operator is the only one that exposes users/commands/keys as CRD fields.
- **On OpenShift?** Hyperspike has the cleanest SCC story.
- **Want per-shard LBs or single Envoy?** Only Hyperspike exposes both.

## Current known gaps

- **Official**: no TLS, no persistence config, no backup/restore, no standalone/Sentinel modes, no Helm install chart yet. API is `v1alpha1` - expect breaking upgrades.
- **Hyperspike**: the `replicas` field creates extra primary nodes rather than per-shard replicas (use `clusterReplicas` for replicas-per-primary). No backup/restore.
- **SAP**: Sentinel-focused, no cluster support.

## Operator vs Helm - when to pick which

Operators own day-2: declarative failover, scaling, cert rotation, ACL sync, resharding. Helm owns day-1: template in a release, get a working instance, walk away. If you want GitOps for topology changes, the operator path pays for itself; if the cluster is static and you manage day-2 out-of-band, Helm's simpler.

## CRD shapes

All three follow the `kubectl explain <kind>` pattern - read the CRD from the cluster rather than copy-pasting from docs:

```sh
kubectl explain valkeycluster.spec --recursive    # official
kubectl explain valkey.spec --recursive           # hyperspike or SAP
```

Key fields on every one: `shards`/`replicas` (or `clusterReplicas`), `resources`, `storage`, `tls` (where supported). See each operator's `config/samples/` directory for golden configs. The official operator additionally exposes `workloadType: StatefulSet | Deployment` (immutable after creation) and a declarative `users[]` list for ACL rules.

## See also

- `kubernetes-operators-day2.md` - SAP operator details, day-2 workflows.
- `kubernetes-helm.md` - chart picker if you don't need an operator.
- `kubernetes-statefulset-config.md` - raw StatefulSet patterns if you're not using either.
