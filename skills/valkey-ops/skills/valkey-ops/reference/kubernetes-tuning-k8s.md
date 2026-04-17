# Kubernetes Tuning - Valkey-specific concerns

Use when running Valkey in K8s and hitting the parts that don't "just work".

Generic prereqs - `vm.overcommit_memory=1`, `net.core.somaxconn=65535`, THP `never`, SSD-backed PVC - are the same as Redis; apply them via node DaemonSet, privileged init container, or (where allowed) pod `securityContext.sysctls`. What follows is what's Valkey-specific or what breaks in ways a Redis-on-K8s agent wouldn't expect.

## Cluster gossip breaks under NAT

Valkey cluster gossip advertises `<ip>:<port>:<bus-port>` between nodes. Bus port is always `port + 10000` - so a pod listening on 6379 also needs 16379 reachable from every other cluster node. Any NAT or Service remapping between pods breaks the protocol.

Three ways to fix:

- **`hostNetwork: true`** - simplest, limits one Valkey pod per node, bypasses NetworkPolicy. Acceptable for dedicated nodes.
- **`cluster-announce-*`** overrides - tell Valkey to announce a different triple than what it binds locally:

  ```sh
  valkey-server /etc/valkey/valkey.conf \
      --cluster-announce-ip   $(hostname -i) \
      --cluster-announce-port 6379 \
      --cluster-announce-bus-port 16379
  ```

  Put in a StatefulSet init script; pod-ip discovery with `hostname -i` is stable because Valkey's own pods are stateful.

- **Operator-managed** - the Hyperspike/SAP operators inject announce-* values for you. See `kubernetes-operators-overview.md`.

Sentinel mode doesn't have the bus port problem - `sentinel announce-ip / announce-port` plus a standard ClusterIP Service is enough. Use Sentinel over cluster mode when the K8s networking stack makes bus routing painful.

## GKE Autopilot

Autopilot blocks `securityContext.sysctls` (no `net.core.somaxconn` bump, no THP disable), forbids privileged init containers, and mandates resource requests. Net effect: you get default sysctls only, and BGSAVE fork behavior on a large dataset is unpredictable. For production Valkey on GKE, use Standard clusters.

## Exporter sidecar sizing

`redis_exporter` as a sidecar talks to Valkey over `localhost` (same pod = no network overhead, no extra Service):

```yaml
- name: exporter
  image: oliver006/redis_exporter:latest
  env:
    - { name: REDIS_ADDR, value: "redis://localhost:6379" }
  resources:
    requests: { memory: 64Mi, cpu: 50m }
    limits:   { memory: 128Mi }
```

The `REDIS_ADDR` env var accepts `valkey://` too, but `redis://localhost:6379` is what every operator emits by default - keep it unless you're hand-rolling.

ServiceMonitor / alert-rule plumbing is identical to Redis; use the Grafana Redis dashboards (community IDs `11835`, `763`) - the `redis_exporter` metric names are stable. See `monitoring-prometheus.md` for Valkey-only metrics worth alerting on beyond the standard panel set.
