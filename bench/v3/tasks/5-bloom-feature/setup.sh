#!/usr/bin/env bash
set -euo pipefail

# Setup script for Task 5: Bloom Feature Addition
# Clones valkey-bloom from local source to avoid network dependency.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE="$SCRIPT_DIR/workspace"
LOCAL_BLOOM_REPO="/c/Users/avife/agent-sh/valkey-bloom"
TARGET="$WORKSPACE/valkey-bloom"

if [[ -d "$TARGET" ]]; then
  echo "[SKIP] $TARGET already exists"
  exit 0
fi

if [[ ! -d "$LOCAL_BLOOM_REPO/.git" ]]; then
  echo "[ERROR] Local valkey-bloom repo not found at $LOCAL_BLOOM_REPO"
  exit 1
fi

echo "[SETUP] Cloning valkey-bloom from local repo..."
git clone --no-hardlinks "$LOCAL_BLOOM_REPO" "$TARGET"

# Detach from origin so the agent cannot accidentally push
cd "$TARGET"
git remote remove origin 2>/dev/null || true

echo "[OK] valkey-bloom cloned to $TARGET"
