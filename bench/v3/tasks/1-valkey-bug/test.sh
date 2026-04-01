#!/usr/bin/env bash
set -euo pipefail

# Test script for Task 1: Valkey Bug Investigation
# Usage: test.sh <workspace_dir>
# Checks ANALYSIS.md for 7 required elements

WORK_DIR="${1:-.}"
ANALYSIS="$WORK_DIR/ANALYSIS.md"

if [[ ! -f "$ANALYSIS" ]]; then
  echo "FAIL: ANALYSIS.md not found"
  echo "FAIL: ANALYSIS.md not found"
  echo "FAIL: ANALYSIS.md not found"
  echo "FAIL: ANALYSIS.md not found"
  echo "FAIL: ANALYSIS.md not found"
  echo "FAIL: ANALYSIS.md not found"
  echo "FAIL: ANALYSIS.md not found"
  exit 0
fi

CONTENT=$(cat "$ANALYSIS" | tr '[:upper:]' '[:lower:]')

# 1. Mentions t_hash.c as the source file
if echo "$CONTENT" | grep -qE 't_hash\.c'; then
  echo "PASS: identifies t_hash.c as the source file"
else
  echo "FAIL: does not mention t_hash.c"
fi

# 2. Mentions field existence check (hashTypeExists, hashTypeFind, or similar)
if echo "$CONTENT" | grep -qE 'hashtypeexists|hashtypefind|hashtypelookup|field.?exist|existence.?check|check.*(exists|presence|field)'; then
  echo "PASS: mentions field existence check mechanism"
else
  echo "FAIL: does not mention field existence check (hashTypeExists, hashTypeFind, or equivalent)"
fi

# 3. Explains non-existent fields should not accept TTL
if echo "$CONTENT" | grep -qE '(non.?existent|missing|deleted|absent).*(field|key).*(should|must|need).*(not|reject|refuse|skip|fail|return|check|validate|verify)|(should|must).*(check|verify|validate).*(exist|present|found).*(before|prior)'; then
  echo "PASS: explains non-existent fields should not accept TTL"
else
  echo "FAIL: does not explain that non-existent fields should not accept TTL"
fi

# 4. References hash field metadata or expire structure
if echo "$CONTENT" | grep -qE 'expire.?(metadata|struct|dict|entry|data)|hash.?(field.?)?metadata|hfe|field.?expir(e|ation).?(metadata|struct|dict|stor)|per.?field.?expir'; then
  echo "PASS: references hash field metadata/expire structure"
else
  echo "FAIL: does not reference hash field metadata or expire structure"
fi

# 5. Explains memory leak mechanism
if echo "$CONTENT" | grep -qE 'memory.?(leak|grow|accumulat|orphan)|orphan.*(metadata|entry|ttl|expir)|leak.*(memory|metadata|entry)|accumulat.*(metadata|entry|ttl|expir)|never.*(free|clean|remov|reclaim|expir)'; then
  echo "PASS: explains memory leak mechanism"
else
  echo "FAIL: does not explain memory leak mechanism"
fi

# 6. Proposes adding validation before TTL set
if echo "$CONTENT" | grep -qE '(add|insert|include|introduce|perform).*(check|validation|guard|verify|test).*(before|prior|first)|check.*(field|exist).*(before|prior)|validate.*(field|exist).*(before|prior)|if.*(exist|found|present).*(before|then|set)'; then
  echo "PASS: proposes adding validation before TTL set"
else
  echo "FAIL: does not propose adding validation before TTL set"
fi

# 7. Mentions HTTL or HPERSIST as affected commands
if echo "$CONTENT" | grep -qE 'httl|hpersist|hpttl|hexpireat|hpexpire|hpexpireat'; then
  echo "PASS: mentions related affected commands (HTTL, HPERSIST, or similar)"
else
  echo "FAIL: does not mention HTTL, HPERSIST, or other affected hash TTL commands"
fi
