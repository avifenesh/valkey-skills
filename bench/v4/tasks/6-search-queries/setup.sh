#!/bin/bash
set -e
echo "[INFO] Task 6 requires Docker for valkey-bundle (search module)"
docker pull valkey/valkey-bundle:latest 2>/dev/null || true
