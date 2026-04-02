# Bug Report: Cluster Split-Brain After Network Partition

## Environment
- Valkey cluster: 6 nodes (3 primaries, 3 replicas)
- Built from source in this directory (src/, deps/, Makefile)

## Observed Behavior
After a network partition and recovery:
- Two nodes claim master for the same slot range
- Both have the same configEpoch value
- The cluster stays in this split-brain state indefinitely
- The epoch collision is never resolved

## Steps to Reproduce
Build and run: `docker compose up -d --build`
Then run `./reproduce.sh` to trigger the bug.

## Your Task
1. Find the root cause in the C source code (src/ directory)
2. Fix the bug by editing the source directly
3. The fix must compile: `make -j$(nproc)` must succeed
4. Verify the fix resolves the split-brain

Work only within this directory. The bug is in the C source code.
