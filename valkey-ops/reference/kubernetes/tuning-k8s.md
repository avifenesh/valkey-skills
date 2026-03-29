# Kubernetes Tuning for Valkey

Use when tuning kernel parameters for Valkey in Kubernetes, setting up init containers for sysctl, handling Docker/NAT limitations, or configuring monitoring in K8s.

---

## Kernel Tuning

Valkey requires specific kernel settings for optimal operation. In Kubernetes, these must be applied at the pod or node level since containers share the host kernel.

### Required Kernel Settings

| Setting | Value | Why |
|---------|-------|-----|
| `vm.overcommit_memory` | `1` | Prevents BGSAVE/BGREWRITEAOF fork failures |
| `net.core.somaxconn` | `65535` | TCP listen backlog for high connection counts |
| Transparent Huge Pages | `never` | THP causes latency spikes during fork and memory allocation |

### Pod-Level Sysctl

Some sysctls can be set at the pod level via `securityContext`:

```yaml
spec:
  securityContext:
    sysctls:
      - name: net.core.somaxconn
        value: "65535"
```

Note: only "safe" sysctls are allowed by default. The Kubernetes cluster must have `net.core.somaxconn` in the allowed unsafe sysctls list, or it must be configured as a safe sysctl via the kubelet `--allowed-unsafe-sysctls` flag.

### Init Container for Transparent Huge Pages

THP cannot be set via pod sysctls - it requires host-level access. Use a privileged init container:

```yaml
initContainers:
  - name: disable-thp
    image: busybox
    command:
      - sh
      - -c
      - echo never > /sys/kernel/mm/transparent_hugepage/enabled
    securityContext:
      privileged: true
    volumeMounts:
      - name: sys
        mountPath: /sys
volumes:
  - name: sys
    hostPath:
      path: /sys
```

This requires the pod to have `privileged: true` for the init container, which may conflict with PodSecurityPolicies or PodSecurityStandards.

### Node-Level Tuning via DaemonSet

For clusters where privileged init containers are not allowed, apply tuning at the node level:

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: valkey-node-tuner
  namespace: kube-system
spec:
  selector:
    matchLabels:
      app: valkey-node-tuner
  template:
    metadata:
      labels:
        app: valkey-node-tuner
    spec:
      hostPID: true
      nodeSelector:
        valkey-workload: "true"    # label nodes that run Valkey
      containers:
        - name: tuner
          image: busybox
          command:
            - sh
            - -c
            - |
              sysctl -w vm.overcommit_memory=1
              sysctl -w net.core.somaxconn=65535
              echo never > /sys/kernel/mm/transparent_hugepage/enabled
              echo "Kernel tuning applied"
              sleep infinity
          securityContext:
            privileged: true
          volumeMounts:
            - name: sys
              mountPath: /sys
      volumes:
        - name: sys
          hostPath:
            path: /sys
```

### Managed Kubernetes (EKS, GKE, AKS)

On managed Kubernetes services, node-level tuning options:

| Provider | Method |
|----------|--------|
| AWS EKS | Custom AMI with sysctl in `/etc/sysctl.d/`, or use a DaemonSet |
| GCP GKE | Use a DaemonSet, or configure via node pool `--system-config-from-file` |
| Azure AKS | Use a DaemonSet, or configure via `customLinuxOsConfig` in node pool |

## Docker and NAT Limitations

Valkey Cluster uses a gossip protocol where nodes exchange their IP addresses and two ports (client port and cluster bus port at client+10000). NAT and port remapping break this protocol.

### The Problem

In standard Kubernetes networking:
- Pods have their own IP addresses (no NAT between pods in the same cluster)
- But Docker port mapping (`-p 7000:6379`) and NodePort services remap ports
- Cluster nodes advertise the container's internal address, which may not be routable from other nodes

### Solutions for Cluster Mode

**Option 1: hostNetwork (simplest, least portable)**

```yaml
spec:
  hostNetwork: true
  dnsPolicy: ClusterFirstWithHostNet
```

Pods use the host's network stack directly. No port remapping. Works but limits one Valkey pod per node and bypasses Kubernetes network policies.

**Option 2: Use an operator**

The Hyperspike and similar operators handle cluster bus port routing automatically. They configure `cluster-announce-ip` and `cluster-announce-port` on each pod.

**Option 3: Manual announcement**

Set announcement addresses in the Valkey config:

```
cluster-announce-ip <pod-ip>
cluster-announce-port 6379
cluster-announce-bus-port 16379
```

In a StatefulSet, use an init script to discover the pod IP:

```yaml
command:
  - sh
  - -c
  - |
    POD_IP=$(hostname -i)
    valkey-server /etc/valkey/valkey.conf \
      --cluster-announce-ip $POD_IP \
      --cluster-announce-port 6379 \
      --cluster-announce-bus-port 16379
```

### Sentinel Mode in Kubernetes

Sentinel mode is simpler than Cluster mode in Kubernetes because:
- Sentinel only needs the client port (no bus port)
- Sentinel can use `announce-ip` and `announce-port` to handle NAT
- Pod-to-pod communication works with standard ClusterIP services

```
sentinel announce-ip <pod-ip>
sentinel announce-port 26379
```

## Monitoring in Kubernetes

### Sidecar Pattern: redis_exporter

Deploy the Prometheus exporter as a sidecar container alongside each Valkey pod:

```yaml
containers:
  - name: valkey
    image: valkey/valkey:9
    ports:
      - containerPort: 6379
        name: client
  - name: exporter
    image: oliver006/redis_exporter:latest
    ports:
      - containerPort: 9121
        name: metrics
    env:
      - name: REDIS_ADDR
        value: "redis://localhost:6379"
      - name: REDIS_PASSWORD
        valueFrom:
          secretKeyRef:
            name: valkey-secret
            key: password
    resources:
      requests:
        memory: 64Mi
        cpu: 50m
      limits:
        memory: 128Mi
```

The exporter connects to Valkey on localhost (same pod), so no network overhead.

### ServiceMonitor for Prometheus Operator

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: valkey
  labels:
    release: prometheus    # must match your Prometheus Operator selector
spec:
  selector:
    matchLabels:
      app: valkey
  endpoints:
    - port: metrics
      interval: 15s
      path: /metrics
```

### Service with Metrics Port

```yaml
apiVersion: v1
kind: Service
metadata:
  name: valkey
  labels:
    app: valkey
spec:
  ports:
    - port: 6379
      targetPort: 6379
      name: client
    - port: 9121
      targetPort: 9121
      name: metrics
  selector:
    app: valkey
```

### Key Metrics to Alert On

| Metric | Alert Condition | Severity |
|--------|----------------|----------|
| `redis_up` | `== 0` for 1 min | Critical |
| `redis_memory_used_bytes / redis_memory_max_bytes` | `> 0.9` | Warning |
| `redis_connected_slaves` | `< expected` for 2 min | Warning |
| `redis_master_link_up` | `== 0` for 1 min | Critical |
| `redis_rejected_connections_total` | rate `> 0` | Warning |
| `redis_rdb_last_bgsave_status` | `!= 1` | Warning |
| `redis_commands_duration_seconds_total` | p99 latency spike | Warning |

### Grafana Dashboard

Import the community Redis/Valkey dashboard (Grafana dashboard ID 11835 or 763) and configure the Prometheus data source.

## See Also

- [StatefulSet Patterns](statefulset.md) - raw StatefulSet deployment
- [Helm Charts](helm.md) - chart-based deployment
- [Kubernetes Operators](operators.md) - CRD-based deployment
- [Bare Metal Setup](../deployment/bare-metal.md) - kernel tuning reference for non-K8s
- [Monitoring Prometheus](../monitoring/prometheus.md) - exporter setup
- [Production Checklist](../production-checklist.md) - full pre-launch verification
