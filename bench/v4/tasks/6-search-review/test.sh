#!/usr/bin/env bash
set -euo pipefail

# Test script for Task 6: Code review + add FT.TAGVALS to valkey-search
# Usage: test.sh <workspace_dir>
# Validates review quality, feature implementation, and build success.

WORK_DIR="$(cd "${1:-.}" && pwd)"
SEARCH_DIR="$WORK_DIR/valkey-search"

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

# =========================================
# REVIEW.md CHECKS
# =========================================

echo "Checking REVIEW.md..."

if [ -f "$WORK_DIR/REVIEW.md" ]; then
  check "REVIEW.md exists" 0
else
  check "REVIEW.md exists" 1
fi

if [ -f "$WORK_DIR/REVIEW.md" ]; then
  REVIEW_WORDS=$(wc -w < "$WORK_DIR/REVIEW.md" | tr -d ' ')
  if [ "$REVIEW_WORDS" -ge 300 ]; then
    check "REVIEW.md has 300+ words (actual: $REVIEW_WORDS)" 0
  else
    check "REVIEW.md has 300+ words (actual: $REVIEW_WORDS)" 1
  fi

  # Check that review mentions specific file paths (not just vague descriptions)
  if grep -qE '/|\.cpp|\.cc|\.h' "$WORK_DIR/REVIEW.md" 2>/dev/null; then
    check "REVIEW.md references specific file paths" 0
  else
    check "REVIEW.md references specific file paths" 1
  fi
else
  check "REVIEW.md has 300+ words" 1
  check "REVIEW.md references specific file paths" 1
fi

# =========================================
# IMPLEMENTATION.md CHECKS
# =========================================

echo ""
echo "Checking IMPLEMENTATION.md..."

if [ -f "$WORK_DIR/IMPLEMENTATION.md" ]; then
  check "IMPLEMENTATION.md exists" 0
else
  check "IMPLEMENTATION.md exists" 1
fi

if [ -f "$WORK_DIR/IMPLEMENTATION.md" ]; then
  IMPL_WORDS=$(wc -w < "$WORK_DIR/IMPLEMENTATION.md" | tr -d ' ')
  if [ "$IMPL_WORDS" -ge 200 ]; then
    check "IMPLEMENTATION.md has 200+ words (actual: $IMPL_WORDS)" 0
  else
    check "IMPLEMENTATION.md has 200+ words (actual: $IMPL_WORDS)" 1
  fi
else
  check "IMPLEMENTATION.md has 200+ words" 1
fi

# =========================================
# BUILD CHECK
# =========================================

echo ""
echo "Building valkey-search..."

cd "$SEARCH_DIR"
mkdir -p build
cd build

CMAKE_OUTPUT=$(cmake .. 2>&1) && CMAKE_EXIT=0 || CMAKE_EXIT=$?
if [ "$CMAKE_EXIT" = "0" ]; then
  check "cmake configure succeeds" 0
else
  echo "$CMAKE_OUTPUT" | tail -20
  check "cmake configure succeeds" 1
  echo ""
  echo "========================================="
  echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed out of $((PASS_COUNT + FAIL_COUNT)) checks"
  echo "========================================="
  exit 1
fi

BUILD_OUTPUT=$(make -j"$(nproc)" 2>&1) && BUILD_EXIT=0 || BUILD_EXIT=$?
if [ "$BUILD_EXIT" = "0" ]; then
  check "make build succeeds" 0
else
  echo "$BUILD_OUTPUT" | tail -30
  check "make build succeeds" 1
fi

# =========================================
# SOURCE CODE CHECKS
# =========================================

echo ""
echo "Checking source code for FT.TAGVALS..."

cd "$SEARCH_DIR"

# Check that TAGVALS or tagvals appears in source code
if grep -rqi "TAGVALS\|tagvals" src/ 2>/dev/null; then
  check "TAGVALS referenced in source code" 0
else
  check "TAGVALS referenced in source code" 1
fi

# Check command registration (should appear in module_loader.cc or similar)
if grep -rqi "TAGVALS" src/module_loader.cc src/commands/ 2>/dev/null; then
  check "TAGVALS registered in command system" 0
else
  check "TAGVALS registered in command system" 1
fi

# Check that a test file was created or modified for FT.TAGVALS
TESTS_FOUND=0
# Check C++ unit tests
if grep -rqi "tagvals\|TAGVALS" testing/ 2>/dev/null; then
  TESTS_FOUND=1
fi
# Check Python integration tests
if grep -rqi "tagvals\|TAGVALS" integration/ 2>/dev/null; then
  TESTS_FOUND=1
fi

if [ "$TESTS_FOUND" = "1" ]; then
  check "test exists for FT.TAGVALS" 0
else
  check "test exists for FT.TAGVALS" 1
fi

# =========================================
# RESULTS
# =========================================

echo ""
echo "========================================="
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed out of $((PASS_COUNT + FAIL_COUNT)) checks"
echo "========================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
