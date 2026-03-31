#!/bin/bash
# Validates Task 2 (ioredis to GLIDE migration) - runs against real cluster
# Input: $1 = directory containing agent's migrated code

DIR="$1"
PASS=0
FAIL=0
TOTAL=10

check() {
  local desc="$1"
  local result="$2"
  if [ "$result" -eq 1 ]; then
    echo "  [PASS] $desc"
    PASS=$((PASS + 1))
  else
    echo "  [FAIL] $desc"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== Task 2: ioredis to GLIDE Migration Validation ==="

cd "$DIR"

# Clean any leftover Docker state
docker compose down -v 2>/dev/null || true

# --- Static checks (3) ---

CODE=$(find "$DIR" -name "app.js" | xargs cat 2>/dev/null)

if [ -z "$CODE" ]; then
  echo "  [ERROR] No app.js found"
  echo "Result: 0/$TOTAL passed"
  echo "SCORE=0/$TOTAL"
  exit 0
fi

# Check 1: Uses GlideClusterClient (not ioredis)
uses_glide=$(echo "$CODE" | grep -ci "GlideClusterClient\|valkey-glide\|@valkey/valkey-glide" || true)
still_ioredis=$(echo "$CODE" | grep -c "import.*ioredis\|require.*ioredis\|new Redis" || true)
check "Uses GlideClusterClient (not ioredis)" "$([ "$uses_glide" -gt 0 ] && [ "$still_ioredis" -eq 0 ] && echo 1 || echo 0)"

# Check 2: Has Batch/pipeline equivalent (not ioredis .pipeline())
has_batch=$(echo "$CODE" | grep -ci "Batch\|\.batch\|new Batch\|ClusterTransaction" || true)
has_pipeline=$(echo "$CODE" | grep -c "\.pipeline()" || true)
check "Uses GLIDE Batch (not ioredis pipeline)" "$([ "$has_batch" -gt 0 ] && [ "$has_pipeline" -eq 0 ] && echo 1 || echo 0)"

# Check 3: Has stream operations (XADD, XREADGROUP, XACK)
has_streams=$(echo "$CODE" | grep -ci "xadd\|xreadgroup\|xack\|XADD\|XREADGROUP\|XACK" || true)
check "Stream operations present" "$([ "$has_streams" -gt 0 ] && echo 1 || echo 0)"

# --- Runtime checks (7) ---

echo "  Starting cluster..."
docker compose up -d --build 2>/dev/null

# Wait for cluster to be ready
for i in $(seq 1 30); do
  cluster_ok=$(docker compose exec -T valkey-1 valkey-cli -p 7001 CLUSTER INFO 2>/dev/null | grep -c "cluster_state:ok" || true)
  [ "$cluster_ok" -gt 0 ] && break
  sleep 2
done

check "Cluster is ready" "$([ "$cluster_ok" -gt 0 ] && echo 1 || echo 0)"

if [ "$cluster_ok" -eq 0 ]; then
  echo "  Cluster not ready, skipping runtime checks"
  FAIL=$((FAIL + 6))
  docker compose down -v 2>/dev/null
  echo ""
  echo "Result: $PASS/$TOTAL passed"
  echo "SCORE=$PASS/$TOTAL"
  exit 0
fi

# Wait for app to finish (up to 60s)
echo "  Waiting for app to complete (60s max)..."
for i in $(seq 1 60); do
  app_done=$(docker compose logs app 2>/dev/null | grep -c "=== Results ===" || true)
  app_error=$(docker compose logs app 2>/dev/null | grep -c "Fatal:\|not implemented\|Error:" || true)
  [ "$app_done" -gt 0 ] || [ "$app_error" -gt 0 ] && break
  sleep 1
done

# Check 4: App ran without fatal errors
check "App completed without fatal errors" "$([ "$app_done" -gt 0 ] && [ "$app_error" -eq 0 ] && echo 1 || echo 0)"

# Check 5: Cache data written
cache_exists=$(docker compose exec -T valkey-1 valkey-cli -p 7001 -c EXISTS {cache}:user:1 2>/dev/null | tr -d '[:space:]' || echo "0")
check "Cache data written ({cache}:user:1)" "$([ "$cache_exists" = "1" ] && echo 1 || echo 0)"

# Check 6: Products batch-written (check a few)
product_exists=$(docker compose exec -T valkey-1 valkey-cli -p 7001 -c HGET {product}:0 name 2>/dev/null | tr -d '[:space:]' || echo "")
check "Batch products written ({product}:0)" "$([ -n "$product_exists" ] && [ "$product_exists" != "" ] && echo 1 || echo 0)"

# Check 7: Stream exists with messages
stream_len=$(docker compose exec -T valkey-1 valkey-cli -p 7001 -c XLEN "{stream}:tasks" 2>/dev/null | tr -d '[:space:]' || echo "0")
check "Stream has messages (XLEN > 0)" "$([ "$stream_len" -gt 0 ] && echo 1 || echo 0)"

# Check 8: Consumer group exists
group_exists=$(docker compose exec -T valkey-1 valkey-cli -p 7001 -c XINFO GROUPS "{stream}:tasks" 2>/dev/null | grep -c "workers" || true)
check "Consumer group created" "$([ "$group_exists" -gt 0 ] && echo 1 || echo 0)"

# Check 9: Sorted set populated
zcard=$(docker compose exec -T valkey-1 valkey-cli -p 7001 -c ZCARD leaderboard:daily 2>/dev/null | tr -d '[:space:]' || echo "0")
check "Sorted set populated ($zcard members)" "$([ "$zcard" -gt 0 ] && echo 1 || echo 0)"

# Cleanup
docker compose down -v 2>/dev/null

cd - > /dev/null

echo ""
echo "Result: $PASS/$TOTAL passed"
echo "SCORE=$PASS/$TOTAL"
