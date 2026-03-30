# Pre-Deployment Checklist

Complete before deploying to production or shared clusters.

## Prerequisites

- [ ] Kubernetes cluster 1.23+ available
- [ ] kubectl CLI installed and authenticated
- [ ] OpenSSL installed for certificate generation
- [ ] At least 3 worker nodes with sufficient capacity
- [ ] StorageClass "standard" available (or edit StatefulSet)
- [ ] 12Gi memory available (6 nodes × 2Gi limit)
- [ ] 120Gi storage available (6 nodes × 20Gi PVC)

Check:
```bash
kubectl get nodes -o wide
kubectl get storageclass
kubectl top nodes  # if metrics available
```

## Security Review

- [ ] Password changed from `valkeypassword123` (valkey-cluster-secret.yaml)
- [ ] ConfigMap `requirepass` updated to match (valkey-cluster-configmap.yaml)
- [ ] TLS certificates generated with `generate-tls.sh`
- [ ] Certificates valid for intended domain (check CN and SAN)
- [ ] Private keys permissions set to 600
- [ ] No private keys committed to version control
- [ ] Consider using cert-manager for production automation
- [ ] Plan for certificate rotation strategy (90-day minimum)

Verify certificates:
```bash
openssl x509 -in tls-certs/server.crt -noout -text | head -20
```

## Configuration Review

- [ ] maxmemory matches available node memory (default: 1gb)
- [ ] PVC size appropriate for persistence type:
  - [ ] Cache-only: 2-4Gi
  - [ ] AOF: 10-50Gi per expected dataset
  - [ ] RDB: 10-50Gi per expected dataset
- [ ] appendfsync setting acceptable for your durability needs
- [ ] Understood cluster-require-full-coverage trade-off (currently: no)
- [ ] Ready to handle cluster_state:fail scenarios
- [ ] Understood maxmemory-policy (currently: allkeys-lru)

Check configuration:
```bash
kubectl get configmap valkey-config -n valkey-cluster -o yaml | grep -A 50 "data:"
```

## Network & DNS

- [ ] Cluster DNS resolves pod names (test from pod)
- [ ] Pods can reach external DNS if needed
- [ ] Network Policy (if enabled) allows:
  - [ ] Pod-to-pod on 6379/TCP
  - [ ] Pod-to-pod on 16379/TCP
  - [ ] Pod-to-DNS on 53/UDP
- [ ] LoadBalancer service capable of provisioning IP
- [ ] Firewall allows inbound on 6379 to LoadBalancer

Test connectivity:
```bash
kubectl run -it --image=alpine --rm debug --restart=Never -- \
  nslookup valkey-0.valkey-cluster.valkey-cluster.svc.cluster.local
```

## Capacity Planning

- [ ] Memory: Requests = maxmemory + ~200MB overhead
- [ ] Memory: Limits ≥ 2× requests (for fork during BGSAVE/BGREWRITEAOF)
- [ ] CPU: 500m per node is minimum; consider 1000m+ for high throughput
- [ ] CPU: No CPU limits set (avoid throttling on latency-sensitive workload)
- [ ] Storage: 3× dataset size minimum (for AOF + snapshots)
- [ ] Node capacity: Can accommodate all 6 pods with anti-affinity

Check capacity:
```bash
kubectl describe nodes | grep -A 5 "Allocated resources"
```

## High Availability

- [ ] Pod Disruption Budget minAvailable: 4 (correct for 6 pods)
- [ ] Pod anti-affinity configured (spreading across nodes)
- [ ] Zone anti-affinity planned (if multi-AZ cluster)
- [ ] Understood single-point-of-failure: single LoadBalancer (consider HA proxy)
- [ ] Replica count matches primary count (3+3)
- [ ] Failover recovery tested in staging

Verify PDB:
```bash
kubectl get poddisruptionbudget -n valkey-cluster -o yaml
```

## Monitoring & Observability

- [ ] Prometheus exporter deployed (optional but recommended)
- [ ] Grafana dashboards configured for:
  - [ ] Cluster state and slot coverage
  - [ ] Memory usage vs maxmemory
  - [ ] Replication lag
  - [ ] Ops per second
  - [ ] Network throughput
- [ ] Alerting rules for:
  - [ ] cluster_state != ok
  - [ ] Replication lag > threshold
  - [ ] Memory usage > 80% maxmemory
  - [ ] Pod OOMKilled
- [ ] Log aggregation configured (if using multi-node)
- [ ] Plan for audit logging

Optional: Enable slow log
```bash
# Edit ConfigMap
slowlog-log-slower-than 10000  # microseconds
slowlog-max-len 128
```

## Backup & Disaster Recovery

- [ ] Backup strategy defined:
  - [ ] Frequency (e.g., daily)
  - [ ] Retention period
  - [ ] Storage location (cross-region if possible)
- [ ] Backup automation tested:
  - [ ] BGSAVE or AOF rewrite works
  - [ ] Snapshots copied to safe location
  - [ ] Retention policy applied
- [ ] Restore procedure documented
- [ ] Restore procedure tested on test cluster
- [ ] RTO (Recovery Time Objective) defined
- [ ] RPO (Recovery Point Objective) achievable with strategy

Test backup:
```bash
kubectl exec -it valkey-0 -n valkey-cluster -- valkey-cli \
  --tls --cacert /etc/valkey/tls/ca.crt \
  -a valkeypassword123 \
  BGSAVE

# Then copy /data/dump.rdb or check AOF
```

## Scaling Plan

- [ ] Cluster size fixed at 3 primaries + 3 replicas (no auto-scaling)
- [ ] Plan for data growth:
  - [ ] Storage expansion procedure
  - [ ] Memory expansion procedure
  - [ ] When to shard/partition data
- [ ] Understood resharding complexity (requires planned maintenance)
- [ ] Backup before major topology changes

## Security Hardening (Post-Deployment)

- [ ] ACL users created for applications (instead of requirepass-only)
- [ ] Admin user password rotated from default
- [ ] Dangerous commands disabled (FLUSHDB, FLUSHALL, etc.)
- [ ] NetworkPolicy restricts unauthorized pod access
- [ ] RBAC limits who can access Kubernetes cluster
- [ ] Secret audit logging enabled (for password access)
- [ ] TLS client certificates rotated periodically
- [ ] Considered implementing:
  - [ ] Pod Security Policy or Pod Security Standard
  - [ ] Network Policy for egress restrictions
  - [ ] Resource quotas per namespace
  - [ ] LimitRange for container limits

## Operational Readiness

- [ ] Runbook created for common tasks:
  - [ ] Failover procedures
  - [ ] Emergency restart
  - [ ] Storage expansion
  - [ ] Certificate renewal
- [ ] Incident response plan for:
  - [ ] cluster_state:fail
  - [ ] Replication lag
  - [ ] Out of memory
  - [ ] Node failure
- [ ] Team trained on Valkey cluster operations
- [ ] Escalation contacts defined
- [ ] War room established for incidents

## Pre-Flight Testing

- [ ] Deploy to staging environment first
- [ ] Run through full deployment procedure
- [ ] Execute all test commands from QUICK_REFERENCE.md
- [ ] Run valkey-cluster-test-job.yaml and verify all tests pass
- [ ] Load test with expected throughput
- [ ] Simulate pod failure and verify automatic recovery
- [ ] Simulate node drain and verify PDB prevents data loss
- [ ] Verify external connectivity to LoadBalancer

Run staging test:
```bash
bash deploy.sh  # in staging namespace
```

## Final Sign-Off

- [ ] Architecture reviewed and approved
- [ ] Security review completed
- [ ] Capacity review completed
- [ ] Team trained on operations
- [ ] Runbooks reviewed by team
- [ ] Monitoring and alerting verified
- [ ] Backup and restore procedures tested
- [ ] Staging deployment successful
- [ ] Production credentials prepared (not in Git)

## Day 1 Tasks (After Initial Deployment)

- [ ] Create ACL users for each application
- [ ] Set up Prometheus monitoring and dashboards
- [ ] Configure alerting channels (PagerDuty, Slack, etc.)
- [ ] Test backup procedure end-to-end
- [ ] Document actual performance characteristics
- [ ] Schedule certificate renewal reminder (365 days)
- [ ] Conduct post-deployment review meeting
- [ ] Update runbooks with actual Kubernetes cluster details
- [ ] Set up on-call schedule for cluster support

## Common Gotchas to Avoid

- [ ] Don't use plaintext password in ConfigMap - use encrypted secret
- [ ] Don't forget maxmemory tuning - OOM kills are preventable
- [ ] Don't set CPU limits - causes latency spikes
- [ ] Don't commit real certificates to Git
- [ ] Don't ignore Pod Disruption Budget warnings
- [ ] Don't assume single-node cluster for testing - test on multi-node
- [ ] Don't forget to update client configuration with cluster endpoints
- [ ] Don't mix cluster-enabled and standalone configs
- [ ] Don't use requirepass-only auth in production - add ACL users
- [ ] Don't forget to test failover before going live

## Sign-Off

- [ ] Prepared by: ___________________  Date: _______________
- [ ] Reviewed by: ___________________  Date: _______________
- [ ] Approved for production: ___________________  Date: _______________

## Notes

```
_________________________________________________________________

_________________________________________________________________

_________________________________________________________________
```
