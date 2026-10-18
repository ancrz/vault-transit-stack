#!/usr/bin/env bash
# Stop the stack. Data (data/) and secrets (secrets/) are kept; the next start auto-unseals.
set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
docker compose down "$@"
