# Bug Report

We built Valkey from the source code in this directory. After deploying a 6-node cluster (3 primaries, 3 replicas), we observed the following issue:

When a primary node is disconnected from the network and then reconnected after a failover occurs, the cluster enters a permanent split-brain state. Two nodes claim to be master of the same slot range with identical configEpoch values. The cluster never recovers on its own.

We've included a script `reproduce.sh` that demonstrates the bug (requires Docker).

A known-good Valkey 9.0.3 build does NOT have this problem - the issue was introduced in our modified source.

Please:
1. Find and fix the bug in the source code
2. The code must compile successfully after your fix

The source tree has ~200 files. The bug is a logic error, not a typo or syntax error.
