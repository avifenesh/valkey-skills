#!/bin/bash
# Reproduces a split-brain bug in this Valkey cluster build.
# Run this script to see the issue, then investigate the root cause.

set -e

echo "=== Starting 6-node Valkey cluster ==="
docker compose up -d --build --wait

echo "=== Waiting for nodes to be ready ==="
sleep 5

echo "=== Creating cluster (3 primaries + 3 replicas) ==="
docker compose exec valkey-1 valkey-cli --cluster create \
  172.30.0.11:7001 172.30.0.12:7002 172.30.0.13:7003 \
  172.30.0.14:7004 172.30.0.15:7005 172.30.0.16:7006 \
  --cluster-replicas 1 --cluster-yes

sleep 3

echo "=== Cluster state before partition ==="
docker compose exec valkey-1 valkey-cli -p 7001 CLUSTER INFO | grep -E "cluster_state|cluster_current_epoch"
docker compose exec valkey-1 valkey-cli -p 7001 CLUSTER NODES

echo "=== Writing test data ==="
for i in $(seq 1 100); do
  docker compose exec valkey-1 valkey-cli -p 7001 -c SET "key:$i" "value:$i" 2>/dev/null || true
done
echo "Wrote 100 keys"

echo ""
echo "=== Simulating network partition ==="
echo "Disconnecting valkey-1 (primary) from the network..."
docker network disconnect 1-bug-investigation_cluster-net 1-bug-investigation-valkey-1-1 2>/dev/null || \
docker network disconnect bench-v2-tasks-1-bug-investigation_cluster-net bench-v2-tasks-1-bug-investigation-valkey-1-1

echo "=== Waiting for failover (15 seconds) ==="
sleep 15

echo "=== Cluster state during partition (from valkey-2) ==="
docker compose exec valkey-2 valkey-cli -p 7002 CLUSTER INFO | grep -E "cluster_state|cluster_current_epoch"
echo "--- Nodes view from valkey-2 ---"
docker compose exec valkey-2 valkey-cli -p 7002 CLUSTER NODES

echo ""
echo "=== Healing partition ==="
echo "Reconnecting valkey-1..."
docker network connect 1-bug-investigation_cluster-net 1-bug-investigation-valkey-1-1 2>/dev/null || \
docker network connect bench-v2-tasks-1-bug-investigation_cluster-net bench-v2-tasks-1-bug-investigation-valkey-1-1

echo "=== Waiting for gossip convergence (10 seconds) ==="
sleep 10

echo ""
echo "========================================="
echo "  POST-PARTITION CLUSTER STATE"
echo "========================================="
echo ""

echo "--- View from valkey-1 ---"
docker compose exec valkey-1 valkey-cli -p 7001 CLUSTER INFO | grep -E "cluster_state|cluster_current_epoch|cluster_slots"
docker compose exec valkey-1 valkey-cli -p 7001 CLUSTER NODES

echo ""
echo "--- View from valkey-2 ---"
docker compose exec valkey-2 valkey-cli -p 7002 CLUSTER INFO | grep -E "cluster_state|cluster_current_epoch|cluster_slots"
docker compose exec valkey-2 valkey-cli -p 7002 CLUSTER NODES

echo ""
echo "========================================="
echo "  BUG: Check if two nodes claim the same slots"
echo "  Look for 'master' entries with overlapping slot ranges"
echo "  and matching currentEpoch values"
echo "========================================="
