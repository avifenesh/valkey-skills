#!/bin/bash
set -e
WORKSPACE="$(cd "$(dirname "$0")" && pwd)/workspace"
if [ -d "$WORKSPACE/valkey-bloom" ]; then
  echo "[SKIP] valkey-bloom already cloned"
  exit 0
fi
git clone https://github.com/valkey-io/valkey-bloom.git "$WORKSPACE/valkey-bloom"
echo "[OK] valkey-bloom cloned"
