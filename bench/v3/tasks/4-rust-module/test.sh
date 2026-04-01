#!/usr/bin/env bash
set -euo pipefail

# Outer test wrapper for Task 4: Rust COUNTER module
# Usage: test.sh <work_dir>

WORK_DIR="${1:-.}"

if [[ ! -d "$WORK_DIR" ]]; then
  echo "FAIL: work directory does not exist: $WORK_DIR"
  exit 0
fi

bash "$WORK_DIR/test.sh" "$WORK_DIR"
