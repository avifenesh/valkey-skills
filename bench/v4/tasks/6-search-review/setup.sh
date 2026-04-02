#!/bin/bash
set -e
WORKSPACE="$(cd "$(dirname "$0")" && pwd)/workspace"
if [ -d "$WORKSPACE/valkey-search" ]; then
  echo "[SKIP] valkey-search already cloned"
  exit 0
fi
git clone https://github.com/valkey-io/valkey-search.git "$WORKSPACE/valkey-search"
echo "[OK] valkey-search cloned"
