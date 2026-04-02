#!/usr/bin/env bash
set -euo pipefail

# Test script for Task 9: Spring Data Redis to Spring Data Valkey Migration
# Usage: test.sh <workspace_dir>
# Validates that the Spring Boot app has been fully migrated from
# spring-data-redis + Jedis to spring-data-valkey + GLIDE Java.

WORK_DIR="$(cd "${1:-.}" && pwd)"
PORT=6509

PASS_COUNT=0
FAIL_COUNT=0

check() {
  local name="$1" result="$2"
  if [ "$result" = "0" ]; then
    echo "PASS: $name"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $name"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

file_has() {
  grep -qE "$1" "$2" 2>/dev/null
}

file_lacks() {
  ! grep -qE "$1" "$2" 2>/dev/null
}

cleanup() {
  valkey-cli -p $PORT SHUTDOWN NOSAVE 2>/dev/null || true
  sleep 1
}
trap cleanup EXIT

# =========================================
# ENVIRONMENT SETUP
# =========================================

echo "Starting valkey-server on port $PORT..."
valkey-server --port $PORT --daemonize yes --loglevel warning --save "" 2>&1 || true
sleep 1

if valkey-cli -p $PORT PING 2>/dev/null | grep -q "PONG"; then
  check "valkey-server started" 0
else
  check "valkey-server started" 1
  echo ""
  echo "========================================="
  echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed out of $((PASS_COUNT + FAIL_COUNT)) checks"
  echo "========================================="
  exit 1
fi

# =========================================
# POM.XML CHECKS
# =========================================

echo ""
echo "Checking pom.xml..."

POM="$WORK_DIR/pom.xml"

if [ ! -f "$POM" ]; then
  echo "FAIL: pom.xml not found"
  echo ""
  echo "========================================="
  echo "Results: 0 passed, 1 failed out of 1 checks"
  echo "========================================="
  exit 1
fi

# Check 1: No spring-boot-starter-data-redis
if file_lacks "spring-boot-starter-data-redis" "$POM"; then
  check "pom.xml: no spring-boot-starter-data-redis" 0
else
  check "pom.xml: no spring-boot-starter-data-redis" 1
fi

# Check 2: No jedis dependency
if file_lacks "<artifactId>jedis</artifactId>" "$POM"; then
  check "pom.xml: no jedis dependency" 0
else
  check "pom.xml: no jedis dependency" 1
fi

# Check 3: Has spring-data-valkey or spring-boot-starter-data-valkey
if file_has "spring-data-valkey|spring-boot-starter-data-valkey" "$POM"; then
  check "pom.xml: has spring-data-valkey dependency" 0
else
  check "pom.xml: has spring-data-valkey dependency" 1
fi

# Check 4: Has valkey-glide dependency
if file_has "valkey-glide" "$POM"; then
  check "pom.xml: has valkey-glide dependency" 0
else
  check "pom.xml: has valkey-glide dependency" 1
fi

# =========================================
# JAVA SOURCE CHECKS
# =========================================

echo ""
echo "Checking Java sources..."

# Find all Java files (exclude test files)
JAVA_SRC_FILES=$(find "$WORK_DIR/src/main" -name "*.java" 2>/dev/null || true)

if [ -z "$JAVA_SRC_FILES" ]; then
  check "Java source files exist" 1
  echo ""
  echo "========================================="
  echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed out of $((PASS_COUNT + FAIL_COUNT)) checks"
  echo "========================================="
  exit 1
fi

# Check 5: No org.springframework.data.redis imports in source
HAS_REDIS_IMPORT=false
for f in $JAVA_SRC_FILES; do
  if file_has "import org\.springframework\.data\.redis" "$f"; then
    HAS_REDIS_IMPORT=true
    echo "  Found redis import in: $f"
    break
  fi
done
if [ "$HAS_REDIS_IMPORT" = "false" ]; then
  check "source: no org.springframework.data.redis imports" 0
else
  check "source: no org.springframework.data.redis imports" 1
fi

# Also check test files for redis imports
JAVA_TEST_FILES=$(find "$WORK_DIR/src/test" -name "*.java" 2>/dev/null || true)

HAS_REDIS_TEST_IMPORT=false
for f in $JAVA_TEST_FILES; do
  if file_has "import org\.springframework\.data\.redis" "$f"; then
    HAS_REDIS_TEST_IMPORT=true
    echo "  Found redis import in test: $f"
    break
  fi
done
if [ "$HAS_REDIS_TEST_IMPORT" = "false" ]; then
  check "tests: no org.springframework.data.redis imports" 0
else
  check "tests: no org.springframework.data.redis imports" 1
fi

# =========================================
# APPLICATION PROPERTIES CHECK
# =========================================

echo ""
echo "Checking application.properties..."

PROPS="$WORK_DIR/src/main/resources/application.properties"

if [ -f "$PROPS" ]; then
  # Check 7: No spring.data.redis properties
  if file_lacks "spring\.data\.redis" "$PROPS"; then
    check "properties: no spring.data.redis prefix" 0
  else
    check "properties: no spring.data.redis prefix" 1
  fi

  # Check 8: Has spring.data.valkey properties
  if file_has "spring\.data\.valkey" "$PROPS"; then
    check "properties: has spring.data.valkey prefix" 0
  else
    check "properties: has spring.data.valkey prefix" 1
  fi
else
  check "properties: application.properties exists" 1
  check "properties: has spring.data.valkey prefix" 1
fi

# =========================================
# MAVEN BUILD CHECK
# =========================================

echo ""
echo "Running Maven compile..."
cd "$WORK_DIR"

if mvn compile -q -B 2>&1; then
  check "mvn compile succeeds" 0
else
  check "mvn compile succeeds" 1
fi

# =========================================
# MAVEN TEST EXECUTION
# =========================================

echo ""
echo "Running Maven tests..."
cd "$WORK_DIR"
TEST_OUTPUT=$(mvn test -B 2>&1) && TEST_EXIT=0 || TEST_EXIT=$?

echo "$TEST_OUTPUT" | tail -30

# Count test results from Maven surefire output
TESTS_RUN=$(echo "$TEST_OUTPUT" | grep -E "Tests run:" | tail -1 | grep -oE "Tests run: [0-9]+" | grep -oE "[0-9]+" || echo "0")
TESTS_FAILURES=$(echo "$TEST_OUTPUT" | grep -E "Tests run:" | tail -1 | grep -oE "Failures: [0-9]+" | grep -oE "[0-9]+" || echo "0")
TESTS_ERRORS=$(echo "$TEST_OUTPUT" | grep -E "Tests run:" | tail -1 | grep -oE "Errors: [0-9]+" | grep -oE "[0-9]+" || echo "0")

echo ""
echo "Maven test results: $TESTS_RUN run, $TESTS_FAILURES failures, $TESTS_ERRORS errors"

# Check 9: At least 6 tests run
if [ "$TESTS_RUN" -ge 6 ] 2>/dev/null; then
  check "maven test: 6+ tests run" 0
else
  check "maven test: 6+ tests run ($TESTS_RUN run)" 1
fi

# Check 10: Zero failures and errors
TOTAL_BAD=$((TESTS_FAILURES + TESTS_ERRORS))
if [ "$TOTAL_BAD" -eq 0 ] && [ "$TESTS_RUN" -gt 0 ] 2>/dev/null; then
  check "maven test: zero failures/errors" 0
else
  check "maven test: zero failures/errors ($TESTS_FAILURES failures, $TESTS_ERRORS errors)" 1
fi

# =========================================
# SUMMARY
# =========================================

echo ""
echo "========================================="
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed out of $((PASS_COUNT + FAIL_COUNT)) checks"
echo "========================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
