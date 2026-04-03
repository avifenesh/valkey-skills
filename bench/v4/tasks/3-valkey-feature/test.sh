#!/usr/bin/env bash
set -uo pipefail

# Test script for Task 3: Valkey Feature - Replica reads from replica
# Usage: test.sh <workspace_dir>
#
# Agent must design and implement replica-source-priority config directive
# for chained/cascading replication (replicas syncing from other replicas).

WORK_DIR="$(cd "${1:-.}" && pwd)"

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

DESIGN="$WORK_DIR/DESIGN.md"
CONFIG_SRC="$WORK_DIR/src/config.c"
SERVER_H="$WORK_DIR/src/server.h"
REPL_SRC="$WORK_DIR/src/replication.c"

# =========================================
# DESIGN DOCUMENT
# =========================================

echo "=== Design Document ==="

# Check 1: DESIGN.md exists
if [ -f "$DESIGN" ]; then
  check "DESIGN.md exists" 0
else
  check "DESIGN.md exists" 1
fi

# Check 2: DESIGN.md has 200+ words
if [ -f "$DESIGN" ]; then
  WORD_COUNT=$(wc -w < "$DESIGN" 2>/dev/null || echo 0)
  if [ "$WORD_COUNT" -ge 200 ]; then
    check "DESIGN.md has 200+ words ($WORD_COUNT)" 0
  else
    check "DESIGN.md has 200+ words ($WORD_COUNT)" 1
  fi
else
  check "DESIGN.md has 200+ words" 1
fi

# Check 3: DESIGN.md mentions PSYNC or partial resync
if [ -f "$DESIGN" ]; then
  PSYNC_FOUND=$(grep -ci 'psync\|partial.resync\|partial resync' "$DESIGN" 2>/dev/null || echo 0)
  if [ "$PSYNC_FOUND" -ge 1 ]; then
    check "DESIGN.md mentions PSYNC or partial resync" 0
  else
    check "DESIGN.md mentions PSYNC or partial resync" 1
  fi
else
  check "DESIGN.md mentions PSYNC or partial resync" 1
fi

# Check 4: DESIGN.md mentions failover or failure scenario
if [ -f "$DESIGN" ]; then
  FAILOVER_FOUND=$(grep -ci 'failover\|failure.scenario\|failure scenario' "$DESIGN" 2>/dev/null || echo 0)
  if [ "$FAILOVER_FOUND" -ge 1 ]; then
    check "DESIGN.md mentions failover or failure scenarios" 0
  else
    check "DESIGN.md mentions failover or failure scenarios" 1
  fi
else
  check "DESIGN.md mentions failover or failure scenarios" 1
fi

# Check 5: DESIGN.md mentions replication offset or backlog
if [ -f "$DESIGN" ]; then
  OFFSET_FOUND=$(grep -ci 'replication.offset\|repl.offset\|backlog' "$DESIGN" 2>/dev/null || echo 0)
  if [ "$OFFSET_FOUND" -ge 1 ]; then
    check "DESIGN.md mentions replication offset or backlog" 0
  else
    check "DESIGN.md mentions replication offset or backlog" 1
  fi
else
  check "DESIGN.md mentions replication offset or backlog" 1
fi

# =========================================
# SOURCE CODE CHANGES
# =========================================

echo ""
echo "=== Source Code Changes ==="

# Check 6: Source modified (config.c or server.h or replication.c changed)
MODIFIED=1
if [ -f "$CONFIG_SRC" ]; then
  HAS_FEATURE=$(grep -c 'replica.source.priority' "$CONFIG_SRC" 2>/dev/null || echo 0)
  if [ "$HAS_FEATURE" -ge 1 ]; then
    MODIFIED=0
  fi
fi
if [ "$MODIFIED" = "1" ] && [ -f "$SERVER_H" ]; then
  HAS_FEATURE=$(grep -c 'replica.source.priority' "$SERVER_H" 2>/dev/null || echo 0)
  if [ "$HAS_FEATURE" -ge 1 ]; then
    MODIFIED=0
  fi
fi
if [ "$MODIFIED" = "1" ] && [ -f "$REPL_SRC" ]; then
  HAS_FEATURE=$(grep -c 'replica.source.priority' "$REPL_SRC" 2>/dev/null || echo 0)
  if [ "$HAS_FEATURE" -ge 1 ]; then
    MODIFIED=0
  fi
fi
check "Source modified with new feature" "$MODIFIED"

# Check 7: replica-source-priority appears in source code
PRIORITY_FOUND=0
for f in "$CONFIG_SRC" "$SERVER_H" "$REPL_SRC"; do
  if [ -f "$f" ]; then
    COUNT=$(grep -c 'replica.source.priority' "$f" 2>/dev/null || echo 0)
    PRIORITY_FOUND=$((PRIORITY_FOUND + COUNT))
  fi
done
if [ "$PRIORITY_FOUND" -ge 1 ]; then
  check "replica-source-priority in source code" 0
else
  check "replica-source-priority in source code" 1
fi

# Check 8: primary-only or prefer-replica or auto value appears in source
VALUES_FOUND=0
for f in "$CONFIG_SRC" "$SERVER_H" "$REPL_SRC"; do
  if [ -f "$f" ]; then
    COUNT=$(grep -c 'primary.only\|prefer.replica\|REPLICA_SOURCE' "$f" 2>/dev/null || echo 0)
    VALUES_FOUND=$((VALUES_FOUND + COUNT))
  fi
done
if [ "$VALUES_FOUND" -ge 1 ]; then
  check "Config values (primary-only/prefer-replica/auto) in source" 0
else
  check "Config values (primary-only/prefer-replica/auto) in source" 1
fi

# Check 9: replication.c modified with new logic
if [ -f "$REPL_SRC" ]; then
  REPL_NEW=$(grep -c 'replica.source.priority\|selectReplicaSource\|cascading\|chained\|sibling' "$REPL_SRC" 2>/dev/null || echo 0)
  if [ "$REPL_NEW" -ge 1 ]; then
    check "replication.c has new replica selection logic" 0
  else
    check "replication.c has new replica selection logic" 1
  fi
else
  check "replication.c has new replica selection logic" 1
fi

# =========================================
# COMPILATION
# =========================================

echo ""
echo "=== Compilation ==="
echo "Building valkey (make -j4)..."
cd "$WORK_DIR"
if make -j4 > /dev/null 2>&1; then
  check "make succeeds" 0
else
  check "make succeeds" 1
fi

# =========================================
# SUMMARY
# =========================================

echo ""
echo "========================================="
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed out of $((PASS_COUNT + FAIL_COUNT)) checks"
echo "========================================="
