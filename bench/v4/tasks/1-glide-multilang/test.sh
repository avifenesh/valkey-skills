#!/usr/bin/env bash
set -uo pipefail

# Test script for Task 1: GLIDE Multi-Language Microservices
# Usage: test.sh <workspace_dir>
# Validates that all three services use correct GLIDE APIs.

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

# Helper: check if a pattern appears in a file (case-sensitive)
file_has() {
  grep -qE "$1" "$2" 2>/dev/null
}

# Helper: check if a pattern does NOT appear in a file
file_lacks() {
  ! grep -qE "$1" "$2" 2>/dev/null
}

# =========================================
# GO SERVICE CHECKS
# =========================================

GO_DIR="$WORK_DIR/leaderboard-go"
GO_MAIN="$GO_DIR/main.go"
GO_MOD="$GO_DIR/go.mod"

# Check 1: go.mod exists and has correct GLIDE dependency
if [ -f "$GO_MOD" ] && file_has "valkey-io/valkey-glide/go" "$GO_MOD"; then
  check "Go: go.mod has valkey-glide dependency" 0
else
  check "Go: go.mod has valkey-glide dependency" 1
fi

# Check 2: main.go exists
if [ -f "$GO_MAIN" ]; then
  check "Go: main.go exists" 0
else
  check "Go: main.go exists" 1
fi

# Check 3: No go-redis or redis imports
if [ -f "$GO_MAIN" ] && file_lacks "go-redis|github.com/redis" "$GO_MAIN"; then
  check "Go: no go-redis/redis imports" 0
else
  check "Go: no go-redis/redis imports" 1
fi

# Check 4: Uses glide.NewClient or config builder pattern
if [ -f "$GO_MAIN" ] && file_has "glide\.NewClient|NewClientConfiguration" "$GO_MAIN"; then
  check "Go: uses GLIDE client creation" 0
else
  check "Go: uses GLIDE client creation" 1
fi

# Check 5: Uses .IsNil() not redis.Nil
if [ -f "$GO_MAIN" ] && file_has "\.IsNil\(\)" "$GO_MAIN"; then
  check "Go: uses .IsNil() pattern" 0
else
  check "Go: uses .IsNil() pattern" 1
fi

# Check 6: Does NOT use redis.Nil error pattern
if [ -f "$GO_MAIN" ] && file_lacks "redis\.Nil" "$GO_MAIN"; then
  check "Go: no redis.Nil error pattern" 0
else
  check "Go: no redis.Nil error pattern" 1
fi

# Check 7: Uses Result type from GLIDE
if [ -f "$GO_MAIN" ] && file_has "Result\[" "$GO_MAIN"; then
  check "Go: uses Result[T] type" 0
else
  check "Go: uses Result[T] type" 1
fi

# Check 8: Uses context parameter
if [ -f "$GO_MAIN" ] && file_has "context\.Background\(\)|ctx context\.Context" "$GO_MAIN"; then
  check "Go: uses context" 0
else
  check "Go: uses context" 1
fi

# Check 9: Go build succeeds (syntax check only - no network needed)
if [ -f "$GO_MOD" ]; then
  cd "$GO_DIR"
  if go vet ./... 2>/dev/null; then
    check "Go: go vet passes" 0
  else
    # Fallback: just check that Go files parse
    if go build -o /dev/null ./... 2>/dev/null; then
      check "Go: go build passes" 0
    else
      check "Go: go vet/build passes" 1
    fi
  fi
  cd "$WORK_DIR"
else
  check "Go: go vet/build passes (no go.mod)" 1
fi

# =========================================
# NODE.JS SERVICE CHECKS
# =========================================

NODE_DIR="$WORK_DIR/chat-nodejs"
NODE_CHAT="$NODE_DIR/src/chat.ts"
NODE_PKG="$NODE_DIR/package.json"

# Check 10: package.json exists and has @valkey/valkey-glide
if [ -f "$NODE_PKG" ] && file_has "@valkey/valkey-glide" "$NODE_PKG"; then
  check "Node: package.json has @valkey/valkey-glide" 0
else
  check "Node: package.json has @valkey/valkey-glide" 1
fi

# Check 11: chat.ts exists
if [ -f "$NODE_CHAT" ]; then
  check "Node: src/chat.ts exists" 0
else
  check "Node: src/chat.ts exists" 1
fi

# Check 12: Uses GlideClusterClient
if [ -f "$NODE_CHAT" ] && file_has "GlideClusterClient" "$NODE_CHAT"; then
  check "Node: uses GlideClusterClient" 0
else
  check "Node: uses GlideClusterClient" 1
fi

# Check 13: Uses PubSubChannelModes
if [ -f "$NODE_CHAT" ] && file_has "PubSubChannelModes" "$NODE_CHAT"; then
  check "Node: uses PubSubChannelModes" 0
else
  check "Node: uses PubSubChannelModes" 1
fi

# Check 14: publish() arg order - message first, not channel first
# GLIDE: publish(message, channel) not publish(channel, message)
if [ -f "$NODE_CHAT" ] && file_has "\.publish\(" "$NODE_CHAT"; then
  # Check that it does NOT look like publish(channel, message) pattern
  # A correct call has the message/payload as the first arg
  if file_lacks "\.publish\(channel" "$NODE_CHAT"; then
    check "Node: publish() arg order (message first)" 0
  else
    check "Node: publish() arg order (message first)" 1
  fi
else
  check "Node: publish() called" 1
fi

# Check 15: No ioredis imports
if [ -f "$NODE_CHAT" ] && file_lacks "ioredis|from ['\"]redis['\"]" "$NODE_CHAT"; then
  check "Node: no ioredis/redis imports" 0
else
  check "Node: no ioredis/redis imports" 1
fi

# Check 16: Uses Batch or ClusterBatch (not pipeline())
ALL_NODE_FILES=$(find "$NODE_DIR/src" -name "*.ts" 2>/dev/null)
if [ -n "$ALL_NODE_FILES" ]; then
  HAS_BATCH=false
  for f in $ALL_NODE_FILES; do
    if file_has "Batch|ClusterBatch" "$f"; then
      HAS_BATCH=true
      break
    fi
  done
  # Batch is optional for chat service - only check no .pipeline() usage
  HAS_PIPELINE=false
  for f in $ALL_NODE_FILES; do
    if file_has "\.pipeline\(\)" "$f"; then
      HAS_PIPELINE=true
      break
    fi
  done
  if [ "$HAS_PIPELINE" = "false" ]; then
    check "Node: no .pipeline() calls (GLIDE uses Batch)" 0
  else
    check "Node: no .pipeline() calls (GLIDE uses Batch)" 1
  fi
else
  check "Node: TypeScript source files exist" 1
fi

# Check 17: npm install and build
if [ -f "$NODE_PKG" ]; then
  cd "$NODE_DIR"
  if npm install --ignore-scripts 2>/dev/null && npx tsc --noEmit 2>/dev/null; then
    check "Node: TypeScript compiles" 0
  else
    check "Node: TypeScript compiles" 1
  fi
  cd "$WORK_DIR"
else
  check "Node: TypeScript compiles (no package.json)" 1
fi

# =========================================
# PYTHON SERVICE CHECKS
# =========================================

PY_DIR="$WORK_DIR/stats-python"
PY_MAIN="$PY_DIR/stats.py"
PY_REQS="$PY_DIR/requirements.txt"

# Check 18: requirements.txt exists and has valkey-glide
if [ -f "$PY_REQS" ] && file_has "valkey-glide" "$PY_REQS"; then
  check "Python: requirements.txt has valkey-glide" 0
else
  check "Python: requirements.txt has valkey-glide" 1
fi

# Check 19: stats.py exists
if [ -f "$PY_MAIN" ]; then
  check "Python: stats.py exists" 0
else
  check "Python: stats.py exists" 1
fi

# Check 20: Uses GlideClient (not redis.Redis)
if [ -f "$PY_MAIN" ] && file_has "GlideClient" "$PY_MAIN"; then
  check "Python: uses GlideClient" 0
else
  check "Python: uses GlideClient" 1
fi

# Check 21: Uses Batch not pipeline
if [ -f "$PY_MAIN" ] && file_has "Batch\(" "$PY_MAIN"; then
  check "Python: uses Batch class" 0
else
  check "Python: uses Batch class" 1
fi

# Check 22: Does NOT use .pipeline()
if [ -f "$PY_MAIN" ] && file_lacks "\.pipeline\(\)" "$PY_MAIN"; then
  check "Python: no .pipeline() calls" 0
else
  check "Python: no .pipeline() calls" 1
fi

# Check 23: Uses invoke_script (not eval/evalsha)
if [ -f "$PY_MAIN" ] && file_has "invoke_script" "$PY_MAIN"; then
  check "Python: uses invoke_script" 0
else
  check "Python: uses invoke_script" 1
fi

# Check 24: Uses Script class
if [ -f "$PY_MAIN" ] && file_has "Script\(" "$PY_MAIN"; then
  check "Python: uses Script class" 0
else
  check "Python: uses Script class" 1
fi

# Check 25: Does NOT use eval/evalsha directly
if [ -f "$PY_MAIN" ] && file_lacks "\.eval\(|\.evalsha\(" "$PY_MAIN"; then
  check "Python: no direct eval/evalsha" 0
else
  check "Python: no direct eval/evalsha" 1
fi

# Check 26: Uses async/await
if [ -f "$PY_MAIN" ] && file_has "async def|await " "$PY_MAIN"; then
  check "Python: uses async/await" 0
else
  check "Python: uses async/await" 1
fi

# Check 27: Python syntax check
if [ -f "$PY_MAIN" ]; then
  if python3 -c "import ast; ast.parse(open('$PY_MAIN').read())" 2>/dev/null; then
    check "Python: syntax valid" 0
  elif python -c "import ast; ast.parse(open('$PY_MAIN').read())" 2>/dev/null; then
    check "Python: syntax valid" 0
  else
    check "Python: syntax valid" 1
  fi
else
  check "Python: syntax valid (no stats.py)" 1
fi

# Check 28: No redis-py imports
if [ -f "$PY_MAIN" ] && file_lacks "import redis|from redis" "$PY_MAIN"; then
  check "Python: no redis-py imports" 0
else
  check "Python: no redis-py imports" 1
fi

echo ""
echo "========================================="
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed out of $((PASS_COUNT + FAIL_COUNT)) checks"
echo "========================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
