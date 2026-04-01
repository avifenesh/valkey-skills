#!/usr/bin/env bash
# Test script for Task 3: Ops Production Hardening
# Usage: test.sh <work_dir>
# Outputs PASS:/FAIL: lines for the runner to count.

set -uo pipefail

WORK="$1"
CONF="$WORK/valkey.conf"
AUDIT="$WORK/AUDIT.md"

# Helper: check if a config directive exists with a matching value
conf_has() {
  local directive="$1"
  local pattern="$2"
  grep -qiE "^\s*${directive}\s+${pattern}" "$CONF" 2>/dev/null
}

# Helper: check that a config directive does NOT appear (or is commented out)
conf_absent() {
  local directive="$1"
  # Returns 0 if the directive is absent or only appears commented out
  ! grep -qE "^\s*${directive}\s+" "$CONF" 2>/dev/null
}

# --- 1. Bind address restricted (not 0.0.0.0 alone without auth, or bound to specific interface) ---
# Accept: bind 127.0.0.1, bind with specific IPs, or bind 0.0.0.0 ONLY if requirepass/ACL is set
if conf_has "requirepass" ".+" || grep -qE "^\s*user\s+" "$CONF" 2>/dev/null; then
  # Auth is set, so bind 0.0.0.0 is acceptable if auth protects it
  echo "PASS: 1-bind-or-auth - bind address secured (authentication present)"
elif ! conf_has "bind" "0\.0\.0\.0$"; then
  echo "PASS: 1-bind-or-auth - bind address restricted from 0.0.0.0"
else
  echo "FAIL: 1-bind-or-auth - bind 0.0.0.0 with no authentication"
fi

# --- 2. Protected mode enabled ---
if conf_has "protected-mode" "yes"; then
  echo "PASS: 2-protected-mode - protected-mode yes"
elif conf_has "requirepass" ".+" || grep -qE "^\s*user\s+" "$CONF" 2>/dev/null; then
  # If auth is configured, protected-mode is less critical but should still be on
  if conf_absent "protected-mode" || conf_has "protected-mode" "yes"; then
    echo "PASS: 2-protected-mode - protected-mode default with auth present"
  else
    echo "FAIL: 2-protected-mode - protected-mode explicitly set to no"
  fi
else
  echo "FAIL: 2-protected-mode - protected-mode not enabled and no auth"
fi

# --- 3. maxmemory set to a reasonable value ---
# For 32 GB machine, expect something between 16g and 30g
if grep -qiE "^\s*maxmemory\s+[0-9]" "$CONF" 2>/dev/null; then
  mem_val=$(grep -iE "^\s*maxmemory\s+" "$CONF" | tail -1 | awk '{print $2}' | tr '[:upper:]' '[:lower:]')
  # Convert to GB as integer for comparison (awk handles float math)
  case "$mem_val" in
    *gb) num="${mem_val%gb}" ;;
    *g)  num="${mem_val%g}" ;;
    *mb) num=$(echo "${mem_val%mb}" | awk '{printf "%.2f", $1 / 1024}') ;;
    *m)  num=$(echo "${mem_val%m}" | awk '{printf "%.2f", $1 / 1024}') ;;
    *)   num=$(echo "$mem_val" | awk '{printf "%.2f", $1 / 1073741824}') ;;
  esac
  # Accept 16 GB to 30 GB range
  in_range=$(echo "$num" | awk '{print ($1 >= 16 && $1 <= 30) ? "yes" : "no"}')
  if [[ "$in_range" == "yes" ]]; then
    echo "PASS: 3-maxmemory - maxmemory set to reasonable value ($mem_val)"
  else
    echo "FAIL: 3-maxmemory - maxmemory value out of expected range ($mem_val)"
  fi
else
  echo "FAIL: 3-maxmemory - maxmemory not set"
fi

# --- 4. maxmemory-policy is LRU-based ---
if conf_has "maxmemory-policy" "(allkeys-lru|volatile-lru|allkeys-lfu|volatile-lfu)"; then
  echo "PASS: 4-eviction-policy - maxmemory-policy set to eviction-capable policy"
else
  echo "FAIL: 4-eviction-policy - maxmemory-policy not set to LRU/LFU policy"
fi

# --- 5. RDB persistence configured (save directive with intervals) ---
if grep -qE '^\s*save\s+[0-9]+\s+[0-9]+' "$CONF" 2>/dev/null; then
  echo "PASS: 5-rdb-persistence - RDB save schedule configured"
else
  echo "FAIL: 5-rdb-persistence - no RDB save schedule (save \"\" or missing)"
fi

# --- 6. AOF enabled ---
if conf_has "appendonly" "yes"; then
  echo "PASS: 6-aof-enabled - appendonly yes"
else
  echo "FAIL: 6-aof-enabled - AOF not enabled (must survive restart)"
fi

# --- 7. rename-command removed (replaced with ACL or removed entirely) ---
if conf_absent "rename-command"; then
  echo "PASS: 7-no-rename-command - legacy rename-command directives removed"
else
  echo "FAIL: 7-no-rename-command - rename-command still present (use ACL instead)"
fi

# --- 8. TLS configured or explicitly documented as out-of-scope ---
if conf_has "tls-port" "[0-9]+" || conf_has "tls-cert-file" ".+"; then
  echo "PASS: 8-tls - TLS configuration present"
elif grep -qi "tls" "$AUDIT" 2>/dev/null; then
  echo "PASS: 8-tls - TLS addressed in AUDIT.md"
else
  echo "FAIL: 8-tls - TLS not configured and not documented"
fi

# --- 9. io-threads increased for 16-core machine ---
if grep -qE '^\s*io-threads\s+[2-9][0-9]*' "$CONF" 2>/dev/null || grep -qE '^\s*io-threads\s+[1-9][0-9]+' "$CONF" 2>/dev/null; then
  threads=$(grep -E '^\s*io-threads\s+' "$CONF" | tail -1 | awk '{print $2}')
  if [[ "$threads" -ge 2 && "$threads" -le 16 ]] 2>/dev/null; then
    echo "PASS: 9-io-threads - io-threads set to $threads"
  else
    echo "FAIL: 9-io-threads - io-threads value unexpected ($threads)"
  fi
else
  echo "FAIL: 9-io-threads - io-threads still at 1"
fi

# --- 10. latency-monitor-threshold set to nonzero ---
if grep -qE '^\s*latency-monitor-threshold\s+[1-9]' "$CONF" 2>/dev/null; then
  echo "PASS: 10-latency-monitor - latency-monitor-threshold set to nonzero value"
else
  echo "FAIL: 10-latency-monitor - latency-monitor-threshold is 0 or missing"
fi

# --- 11. slowlog-max-len increased ---
if grep -qE '^\s*slowlog-max-len\s+' "$CONF" 2>/dev/null; then
  slen=$(grep -E '^\s*slowlog-max-len\s+' "$CONF" | tail -1 | awk '{print $2}')
  if [[ "$slen" -ge 64 ]] 2>/dev/null; then
    echo "PASS: 11-slowlog-len - slowlog-max-len increased to $slen"
  else
    echo "FAIL: 11-slowlog-len - slowlog-max-len still too low ($slen)"
  fi
else
  echo "FAIL: 11-slowlog-len - slowlog-max-len not configured"
fi

# --- 12. ACL users configured (not just default) ---
if grep -qE '^\s*user\s+\S+' "$CONF" 2>/dev/null || conf_has "aclfile" ".+"; then
  echo "PASS: 12-acl-users - ACL users or aclfile configured"
elif conf_has "requirepass" ".+"; then
  # requirepass alone is minimal auth - partial credit
  echo "PASS: 12-acl-users - authentication via requirepass (ACL preferred but auth present)"
else
  echo "FAIL: 12-acl-users - no ACL users and no authentication configured"
fi
