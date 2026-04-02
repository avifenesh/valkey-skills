#!/usr/bin/env bash
set -euo pipefail

# Setup script for Task 5: Bloom Feature Addition
# Clones valkey-bloom from local source to avoid network dependency.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE="$SCRIPT_DIR/workspace"
LOCAL_BLOOM_REPO="${VALKEY_BLOOM_REPO:-/c/Users/avife/agent-sh/valkey-bloom}"
REMOTE_BLOOM_REPO="https://github.com/valkey-io/valkey-bloom.git"
TARGET="$WORKSPACE/valkey-bloom"

if [[ -d "$TARGET" ]]; then
  echo "[SKIP] $TARGET already exists"
  exit 0
fi

if [[ -d "$LOCAL_BLOOM_REPO/.git" ]]; then
  echo "[SETUP] Cloning valkey-bloom from local repo..."
  git clone --no-hardlinks "$LOCAL_BLOOM_REPO" "$TARGET"
else
  echo "[SETUP] Local repo not found, cloning from GitHub..."
  git clone "$REMOTE_BLOOM_REPO" "$TARGET"
fi

# Detach from origin so the agent cannot accidentally push
cd "$TARGET"
git remote remove origin 2>/dev/null || true

echo "[OK] valkey-bloom cloned to $TARGET"
