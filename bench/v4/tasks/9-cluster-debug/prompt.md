# Production Incident: Valkey Cluster Won't Failover

## Situation
You're oncall and a Valkey cluster alert fired. One of 3 master nodes (172.30.0.11:7001) is down. The cluster is in CLUSTERDOWN state. No automatic failover has occurred despite a healthy replica (172.30.0.15:7005) being available.

The application team is blocked - all writes to slots 0-5460 are failing.

## Available Data
- `cluster-info.txt` - CLUSTER INFO output from a surviving master
- `cluster-nodes.txt` - CLUSTER NODES output from a surviving master
- `valkey.conf` - Configuration used by all nodes
- `replica-log.txt` - Log from the replica that should have taken over
- `master-info.txt` - INFO REPLICATION snapshot from the replica, captured just before the master died

## Your Task
1. Diagnose why automatic failover is not happening
2. Write `diagnosis.md` explaining:
   - The root cause (with specific config values and calculations)
   - Why the replica refuses to failover
   - The exact log line that confirms your diagnosis
3. Write `immediate-fix.md` with:
   - The command to run RIGHT NOW to restore service (within 30 seconds)
   - Step-by-step instructions
4. Write `prevention.md` with:
   - Config changes to prevent this in the future
   - Explain the trade-offs of each change
   - Recommended monitoring alerts

Work only within this directory.
