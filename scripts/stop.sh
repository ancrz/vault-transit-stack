#!/bin/bash
# =============================================================================
# Vault Stack — Shutdown Script
# =============================================================================

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd)"

echo "--- Stopping Vault Stack ---"
cd "$PROJECT_DIR"
docker compose down
echo "--- Vault stopped ---"
