#!/bin/bash
set -e
WORKSPACE="$(cd "$(dirname "$0")" && pwd)/workspace"
if [ -d "$WORKSPACE/valkey-json" ]; then
  echo "[SKIP] valkey-json already cloned"
  exit 0
fi
git clone --depth 1 https://github.com/valkey-io/valkey-json.git "$WORKSPACE/valkey-json"
echo "[OK] valkey-json cloned"
