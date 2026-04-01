#!/usr/bin/env bash
set -uo pipefail

# Task 10: Spring Data Valkey + GLIDE Java - 9 checks
# Usage: test.sh <workspace_dir>

WORK_DIR="${1:-.}"
PASS=0
FAIL=0

check() {
  local name="$1"
  local result="$2"
  if [[ "$result" == "0" ]]; then
    echo "PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $name"
    FAIL=$((FAIL + 1))
  fi
}

# Start Valkey via docker compose
cleanup() {
  cd "$WORK_DIR" && docker compose down -v --remove-orphans 2>/dev/null || true
}
trap cleanup EXIT

cd "$WORK_DIR" && docker compose up -d --wait 2>&1

# Wait for Valkey to be ready
for i in $(seq 1 30); do
  if valkey-cli -p 6411 PING 2>/dev/null | grep -q PONG; then
    break
  fi
  sleep 1
done

POM="$WORK_DIR/pom.xml"

# 1. mvn compile succeeds
cd "$WORK_DIR" && mvn compile -q -B > /dev/null 2>&1
check "mvn compile succeeds" "$?"

# 2. No spring-data-redis in pom.xml
if grep -q "spring-boot-starter-data-redis" "$POM" 2>/dev/null; then
  check "no spring-data-redis in pom.xml" "1"
else
  check "no spring-data-redis in pom.xml" "0"
fi

# 3. Uses spring-data-valkey
if grep -q "spring-boot-starter-data-valkey\|spring-data-valkey" "$POM" 2>/dev/null; then
  check "uses spring-data-valkey" "0"
else
  check "uses spring-data-valkey" "1"
fi

# 4. No jedis in pom.xml
if grep -qi "jedis" "$POM" 2>/dev/null; then
  check "no jedis in pom.xml" "1"
else
  check "no jedis in pom.xml" "0"
fi

# 5. Uses GLIDE or Lettuce driver
if grep -qi "valkey-glide\|glide" "$POM" 2>/dev/null; then
  check "uses GLIDE driver" "0"
elif grep -qi "lettuce" "$POM" 2>/dev/null; then
  check "uses GLIDE driver" "0"
else
  check "uses GLIDE driver" "1"
fi

# 6. Cache works - check for @Cacheable in source and no Redis cache type in properties
PROPS="$WORK_DIR/src/main/resources/application.properties"
CACHE_OK=1
if grep -rq "@Cacheable" "$WORK_DIR/src/main/java/" 2>/dev/null; then
  # Verify cache type is not still set to "redis"
  if grep -q "spring.cache.type=redis" "$PROPS" 2>/dev/null; then
    CACHE_OK=1
  else
    CACHE_OK=0
  fi
fi
check "cache configuration migrated" "$CACHE_OK"

# 7. Sessions work - no RedisTemplate references remain in source
if grep -rq "RedisTemplate" "$WORK_DIR/src/main/java/" 2>/dev/null; then
  check "session service migrated (no RedisTemplate)" "1"
else
  check "session service migrated (no RedisTemplate)" "0"
fi

# 8. Pub/sub works - no RedisMessageListenerContainer in source
if grep -rq "RedisMessageListenerContainer" "$WORK_DIR/src/main/java/" 2>/dev/null; then
  check "pub/sub migrated (no RedisMessageListenerContainer)" "1"
else
  check "pub/sub migrated (no RedisMessageListenerContainer)" "0"
fi

# 9. All 6 tests pass
cd "$WORK_DIR" && mvn test -q -B > /dev/null 2>&1
check "all 6 tests pass (mvn test)" "$?"

echo ""
echo "Results: $PASS passed, $FAIL failed out of $((PASS + FAIL)) checks"
