#!/usr/bin/env bash
set -uo pipefail

# Test script for Task 3: Ops Production Hardening
# Usage: test.sh <work_dir>
# Starts Valkey with the fixed config, verifies settings via valkey-cli, and checks AUDIT.md.

WORK="$1"
CONF="$WORK/valkey.conf"
AUDIT="$WORK/AUDIT.md"
CONTAINER_NAME="valkey-hardening-test"
PORT=6403
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

cleanup() {
    echo "--- Cleanup ---"
    cd "$WORK" && docker-compose down -v --remove-orphans 2>/dev/null || true
}
trap cleanup EXIT

# Helper: check if a config directive exists with a matching value (for grep-based checks)
conf_has() {
    local directive="$1"
    local pattern="$2"
    grep -qiE "^\s*${directive}\s+${pattern}" "$CONF" 2>/dev/null
}

# Helper: check that a config directive does NOT appear (or is commented out)
conf_absent() {
    local directive="$1"
    ! grep -qE "^\s*${directive}\s+" "$CONF" 2>/dev/null
}

# ---- Start Valkey with the fixed config ----
echo "--- Starting Valkey with fixed config ---"
cd "$WORK" && docker-compose up -d 2>&1
# Wait for Valkey to accept connections
STARTED=0
# Detect auth: if requirepass is set in config, use it for CLI
AUTH_PASS=$(grep -E '^\s*requirepass\s+' "$CONF" 2>/dev/null | tail -1 | awk '{print $2}' | tr -d '"' | tr -d "'" || true)
CLI_AUTH=""
if [[ -n "$AUTH_PASS" ]]; then
    CLI_AUTH="-a $AUTH_PASS"
fi

for i in $(seq 1 30); do
    if valkey-cli -p "$PORT" $CLI_AUTH PING 2>/dev/null | grep -q PONG; then
        STARTED=1
        break
    fi
    sleep 1
done

if [[ "$STARTED" == "1" ]]; then
    check "Valkey starts with fixed config" "0"
else
    check "Valkey starts with fixed config" "1"
    echo "Valkey did not start - cannot run runtime checks. Falling back to config-only checks."
fi

# Helper: run valkey-cli command against the running instance
vcli() {
    valkey-cli -p "$PORT" $CLI_AUTH "$@" 2>/dev/null
}

# ---- Runtime checks (require running Valkey) ----
if [[ "$STARTED" == "1" ]]; then

    # ---- Check 1: AUTH works (requirepass or ACL users set) ----
    echo "--- Check 1: Authentication ---"
    # Try connecting WITHOUT auth - should be rejected if auth is configured
    NOAUTH_RESULT=$(valkey-cli -p "$PORT" PING 2>/dev/null)
    if [[ -n "$AUTH_PASS" ]]; then
        # Auth is configured - unauthenticated PING should fail
        if echo "$NOAUTH_RESULT" | grep -qi "NOAUTH\|ERR\|DENIED"; then
            check "Authentication required (unauthenticated PING rejected)" "0"
        elif echo "$NOAUTH_RESULT" | grep -q "PONG"; then
            check "Authentication required (unauthenticated PING rejected - got PONG)" "1"
        else
            check "Authentication required (unauthenticated PING rejected)" "0"
        fi
    else
        # Check if ACL users block default access
        ACL_USERS=$(grep -cE '^\s*user\s+' "$CONF" 2>/dev/null || echo "0")
        if [[ "$ACL_USERS" -gt 0 ]]; then
            check "Authentication configured (ACL users present)" "0"
        else
            check "Authentication configured (no requirepass and no ACL users)" "1"
        fi
    fi

    # ---- Check 2: maxmemory is set (via INFO) ----
    echo "--- Check 2: maxmemory ---"
    MAXMEM=$(vcli INFO memory | grep "maxmemory:" | tr -d '\r' | cut -d: -f2)
    if [[ -n "$MAXMEM" && "$MAXMEM" != "0" ]]; then
        # Convert to GB for display
        MAXMEM_GB=$(echo "$MAXMEM" | awk '{printf "%.1f", $1 / 1073741824}')
        check "maxmemory is set (${MAXMEM_GB} GB via INFO)" "0"
    else
        check "maxmemory is set (got 0 or empty via INFO)" "1"
    fi

    # ---- Check 3: appendonly is on (via INFO) ----
    echo "--- Check 3: AOF persistence ---"
    AOF_ENABLED=$(vcli INFO persistence | grep "aof_enabled:" | tr -d '\r' | cut -d: -f2)
    if [[ "$AOF_ENABLED" == "1" ]]; then
        check "AOF enabled (aof_enabled:1 via INFO)" "0"
    else
        check "AOF enabled (aof_enabled:$AOF_ENABLED via INFO)" "1"
    fi

    # ---- Check 4: io-threads > 1 (via CONFIG GET) ----
    echo "--- Check 4: io-threads ---"
    IO_THREADS=$(vcli CONFIG GET io-threads | tail -1 | tr -d '\r')
    if [[ -n "$IO_THREADS" && "$IO_THREADS" -gt 1 ]] 2>/dev/null; then
        check "io-threads > 1 (got $IO_THREADS via CONFIG GET)" "0"
    else
        check "io-threads > 1 (got '$IO_THREADS' via CONFIG GET)" "1"
    fi

    # ---- Check 5: maxmemory-policy is LRU/LFU (via CONFIG GET) ----
    echo "--- Check 5: eviction policy ---"
    EVICT_POLICY=$(vcli CONFIG GET maxmemory-policy | tail -1 | tr -d '\r')
    if echo "$EVICT_POLICY" | grep -qE "(allkeys-lru|volatile-lru|allkeys-lfu|volatile-lfu)"; then
        check "maxmemory-policy is LRU/LFU ($EVICT_POLICY via CONFIG GET)" "0"
    else
        check "maxmemory-policy is LRU/LFU (got '$EVICT_POLICY' via CONFIG GET)" "1"
    fi

    # ---- Check 6: latency-monitor-threshold > 0 (via CONFIG GET) ----
    echo "--- Check 6: latency monitor ---"
    LAT_THRESH=$(vcli CONFIG GET latency-monitor-threshold | tail -1 | tr -d '\r')
    if [[ -n "$LAT_THRESH" && "$LAT_THRESH" -gt 0 ]] 2>/dev/null; then
        check "latency-monitor-threshold > 0 (got $LAT_THRESH via CONFIG GET)" "0"
    else
        check "latency-monitor-threshold > 0 (got '$LAT_THRESH' via CONFIG GET)" "1"
    fi

    # ---- Check 7: protected-mode is yes (via CONFIG GET) ----
    echo "--- Check 7: protected-mode ---"
    PROT_MODE=$(vcli CONFIG GET protected-mode | tail -1 | tr -d '\r')
    if [[ "$PROT_MODE" == "yes" ]]; then
        check "protected-mode yes (via CONFIG GET)" "0"
    else
        # Auth may make this less critical, but still check
        if [[ -n "$AUTH_PASS" ]]; then
            check "protected-mode yes (got '$PROT_MODE' but auth is present)" "0"
        else
            check "protected-mode yes (got '$PROT_MODE' via CONFIG GET)" "1"
        fi
    fi

else
    # Valkey didn't start - mark runtime checks as failed
    for label in "Authentication" "maxmemory set" "AOF enabled" "io-threads > 1" \
                 "eviction policy" "latency monitor" "protected-mode"; do
        check "$label (Valkey not running)" "1"
    done
fi

# ---- Config file grep checks (always run) ----

# ---- Check 8: RDB persistence configured ----
echo "--- Check 8: RDB persistence (config grep) ---"
if grep -qE '^\s*save\s+[0-9]+\s+[0-9]+' "$CONF" 2>/dev/null; then
    check "RDB save schedule configured in config file" "0"
else
    check "RDB save schedule configured in config file" "1"
fi

# ---- Check 9: rename-command removed ----
echo "--- Check 9: rename-command removed (config grep) ---"
if conf_absent "rename-command"; then
    check "Legacy rename-command directives removed" "0"
else
    check "Legacy rename-command directives removed" "1"
fi

# ---- Check 10: slowlog-max-len increased ----
echo "--- Check 10: slowlog-max-len (config grep) ---"
if grep -qE '^\s*slowlog-max-len\s+' "$CONF" 2>/dev/null; then
    SLEN=$(grep -E '^\s*slowlog-max-len\s+' "$CONF" | tail -1 | awk '{print $2}')
    if [[ "$SLEN" -ge 64 ]] 2>/dev/null; then
        check "slowlog-max-len increased to $SLEN" "0"
    else
        check "slowlog-max-len increased (got $SLEN, expected >= 64)" "1"
    fi
else
    check "slowlog-max-len configured" "1"
fi

# ---- Check 11: TLS configured or documented ----
echo "--- Check 11: TLS ---"
if conf_has "tls-port" "[0-9]+" || conf_has "tls-cert-file" ".+"; then
    check "TLS configuration present" "0"
elif grep -qi "tls" "$AUDIT" 2>/dev/null; then
    check "TLS addressed in AUDIT.md" "0"
else
    check "TLS not configured and not documented" "1"
fi

# ---- Check 12: AUDIT.md exists and has substance ----
echo "--- Check 12: AUDIT.md ---"
if [[ -f "$AUDIT" ]]; then
    LINE_COUNT=$(wc -l < "$AUDIT")
    if [[ "$LINE_COUNT" -ge 20 ]]; then
        check "AUDIT.md exists with substance ($LINE_COUNT lines)" "0"
    else
        check "AUDIT.md exists but too short ($LINE_COUNT lines)" "1"
    fi
else
    check "AUDIT.md exists" "1"
fi

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed out of $((PASS + FAIL)) checks"
