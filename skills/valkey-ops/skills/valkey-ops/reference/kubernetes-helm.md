# Helm Charts for Valkey

Use when picking and operating a Valkey Helm chart.

## Chart picker

| | Official (`valkey/valkey`) | Bitnami (`oci://registry-1.docker.io/bitnamicharts/valkey` + `valkey-cluster`) |
|---|---|---|
| Architectures | standalone, replication | standalone, replication, Sentinel, cluster |
| Cluster mode | no | yes (separate `valkey-cluster` chart) |
| Sentinel | no | yes |
| PDB | create manually | default enabled |
| Auth default | disabled | random password generated |
| Persistence default | disabled | 8Gi PVC enabled |
| ACL-first | yes | password-first (ACL optional) |
| Replica autoscaling (HPA/VPA) | no | yes |
| OpenShift SCC auto-adapt | no | yes |
| Base image | `valkey/valkey` (upstream) | `bitnami/valkey` (hardened, non-root) |
| Chart license | BSD-3-Clause | Apache-2.0 |
| Exporter sidecar | `redis_exporter` | `redis_exporter` |

Pick **official** for clean upstream defaults with ACL-based auth; pick **Bitnami** when you need cluster mode, Sentinel, hardened images, or the built-in ServiceMonitor / autoscaling plumbing.

## Production values that matter

Apply these regardless of chart:

```yaml
persistence:
  size: 10Gi            # 2x expected dataset
  storageClass: fast-ssd

resources:
  requests: { memory: 2Gi, cpu: 500m }
  limits:
    memory: 4Gi         # 2x requests - fork COW headroom
    # no cpu limit - CFS throttling spikes tail latency

pdb:
  enabled: true
  maxUnavailable: 1     # never 0 - blocks drains

podAntiAffinity: soft   # hard = strict node-spread but can't schedule on small clusters

valkeyConfig: |
  maxmemory 2gb
  maxmemory-policy allkeys-lru
  appendonly yes
  aof-use-rdb-preamble yes
  tcp-keepalive 300
```

**Memory limit must exceed maxmemory** by the fork RSS headroom. With AOF rewrite or BGSAVE on a write-heavy dataset, child RSS can approach 2x parent - sizing the K8s limit below that triggers OOMKill during snapshots.

## Migrating Bitnami -> Official

In-place upgrade doesn't work (StatefulSet names, labels, and PVC claims differ). Treat it as a replica-promote migration:

1. Deploy the official chart alongside the Bitnami release.
2. Point the new instance at the Bitnami primary via `replicaof` + `primaryauth`.
3. Wait for `master_link_status:up` and `master_sync_in_progress:0`.
4. Promote the new instance (`REPLICAOF NO ONE`), switch app endpoints.
5. `helm uninstall` the Bitnami release once traffic has drained.

Bitnami chart values use `master:` / `replica:` as the key root; official uses `primary:` / `replica:`. Value files can't be copied 1:1.
