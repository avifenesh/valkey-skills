Our Valkey cluster is down and failover isnt happening. Need help.

I'm oncall right now and we have a production incident. One of our 3 master nodes (172.30.0.11:7001) went down and the cluster is stuck in CLUSTERDOWN state. The replica at 172.30.0.15:7005 is healthy but it hasn't taken over. All writes to slots 0-5460 are failing and the app team is breathing down my neck.

I've pulled the following data from the surviving nodes:
- `cluster-info.txt` - CLUSTER INFO output from a surviving master
- `cluster-nodes.txt` - CLUSTER NODES output from a surviving master
- `valkey.conf` - Configuration used by all nodes
- `replica-log.txt` - Log from the replica that should have taken over
- `master-info.txt` - INFO REPLICATION snapshot from the replica, captured just before the master died

Can you help me figure out what's going on? I need:

1. **`diagnosis.md`** - What is the root cause? I need specific config values and calculations. Why is the replica refusing to failover? Point me to the exact log line that confirms it.

2. **`immediate-fix.md`** - What do I run RIGHT NOW to restore service? Step-by-step, I need this resolved in under 30 seconds.

3. **`prevention.md`** - Once the fire is out, what config changes should we make so this doesn't happen again? Include trade-offs and what monitoring alerts we should set up.

Work only within this directory.
