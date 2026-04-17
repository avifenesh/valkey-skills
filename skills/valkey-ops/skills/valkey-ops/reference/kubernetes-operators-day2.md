# Operator Day-2 and Selection

Use when choosing between the three Valkey operators or running day-2 operations through them.

## Picking an operator (decision matrix)

| Scenario | Pick |
|----------|------|
| Production cluster mode with sharding **today** | Hyperspike |
| Sentinel HA, no sharding, enterprise support | SAP |
| Declarative ACL users as part of the CRD | Official |
| Stable upstream Valkey project alignment | Official (once past `v1alpha1`) |
| Need Bitnami image hardening as the runtime | SAP |
| OpenShift with SCC constraints | Hyperspike |

Full feature matrix in `kubernetes-operators-overview.md`.

## SAP operator (`cache.cs.sap.com/v1alpha1`)

SAP wraps the Bitnami Helm chart with operator lifecycle management. Install via its own Helm chart:

```sh
helm repo add sap https://sap.github.io/valkey-operator/
helm install valkey-operator sap/valkey-operator
```

CRD shape (`kind: Valkey`): `spec.replicas`, `spec.sentinel.enabled` (Sentinel vs static primary topology), `spec.tls.enabled` (cert-manager integration), `spec.persistence`. Auto-generates a binding Secret with connection details (host, port, password, CA cert, sentinel config) - customizable via Go templates. Ships ServiceMonitor + PrometheusRule. Auto-generates topology-spread constraints when not specified.

**`spec.sentinel.enabled` is immutable after creation** - you can't toggle Sentinel mode on an existing deployment.

Static-primary mode (no Sentinel) makes the first pod the primary with no automatic failover. Rarely what you want in prod - use Sentinel mode unless you specifically want a manual-only topology.

## Day-2 commands (all three operators)

All use the same `kubectl patch` pattern - the difference is which CRD and which field names:

```sh
# Official: scale shards/replicas
kubectl patch valkeycluster my-cluster --type merge \
  -p '{"spec":{"shards":6,"replicas":2}}'

# Hyperspike: scale (cluster mode)
kubectl patch valkey my-cluster --type merge \
  -p '{"spec":{"replicas":9,"clusterReplicas":1}}'

# SAP: scale replicas
kubectl patch valkey my-valkey --type merge \
  -p '{"spec":{"replicas":5}}'

# Any of them: bump image version
kubectl patch valkey my-cluster --type merge \
  -p '{"spec":{"image":"valkey/valkey:9.0.3"}}'
```

All operators translate the CRD change into a rolling upgrade. Watch progress via operator logs (`kubectl logs -n valkey-operator-system deploy/valkey-operator-controller-manager` or equivalent) and the CR status subresource (`kubectl describe <kind> <name>`).

## Health check pattern

```sh
kubectl get <kind>                          # status column: Ready / Reconciling / Degraded
kubectl describe <kind> <name>              # conditions: Ready / Progressing / Degraded / ClusterFormed / SlotsAssigned
kubectl logs -n <operator-ns> deploy/<controller>   # operator-level errors
```

The controller-manager deployment name differs per operator; check the namespace you installed into.
