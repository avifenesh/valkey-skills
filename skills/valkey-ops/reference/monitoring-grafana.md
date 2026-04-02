# Grafana Dashboard Setup

Use when configuring Grafana dashboards for Valkey monitoring.

Standard Redis/Grafana setup applies - the `oliver006/redis_exporter` exposes `redis_*` prefixed metrics that Valkey emits identically. All community Redis dashboards work with Valkey. See Redis monitoring docs for general Grafana setup.

## Community Dashboards (work with Valkey)

| Dashboard ID | Name |
|-------------|------|
| 763 | Redis Dashboard for Prometheus Redis Exporter 1.x (canonical) |
| 14091 | Redis Overview |
| 12776 | Redis Cluster Overview |

Dashboard 763 is the canonical choice, maintained by the exporter author.

## Percona PMM (Valkey-Named Dashboards)

Percona PMM ships dedicated Valkey dashboards in `percona/grafana-dashboards` (`dashboards/Valkey/`). These are named `Valkey Overview`, `Valkey Memory`, `Valkey Replication`, etc. - the only dashboards with Valkey-specific naming.

```bash
pmm-admin add external --service-name=valkey-primary \
  --listen-port=9121 --group=valkey
```

## Provisioning

```yaml
# /etc/grafana/provisioning/dashboards/valkey.yaml
apiVersion: 1
providers:
  - name: valkey
    folder: Valkey
    type: file
    options:
      path: /var/lib/grafana/dashboards/valkey
```
