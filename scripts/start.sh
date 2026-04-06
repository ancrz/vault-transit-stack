#!/bin/bash
# =============================================================================
# Vault Stack — Startup Script
# =============================================================================
# Usage:
#   ./scripts/start.sh    Start vault service
# =============================================================================

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd)"

# --- Colors ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# --- Load environment variables ---
if [ -f "$PROJECT_DIR/.env" ]; then
    set -a
    . "$PROJECT_DIR/.env"
    set +a
    log_info "Environment variables loaded from .env"
else
    log_error ".env file not found. Copy .env.example to .env first."
fi

# --- Validate Docker ---
if ! docker info > /dev/null 2>&1; then
    log_error "Docker is not running or you lack permissions."
fi

# --- Validate required variables ---
REQUIRED_VARS="VAULT_TAG VAULT_PORT HOST_UID HOST_GID"
for var in $REQUIRED_VARS; do
    if [ -z "${!var:-}" ]; then
        log_error "Required variable $var is not defined in .env"
    fi
done

# --- Start vault ---
cd "$PROJECT_DIR"
log_info "Starting Vault..."
docker compose up -d --build

# --- Summary ---
log_info ""
log_info "  Vault UI: http://localhost:${VAULT_PORT:-8200}/ui"
log_info ""
log_info "  Vault starts SEALED. To unseal, run:"
log_info "    cd ansible && ansible-playbook vault-unseal.yml --ask-vault-pass"
log_info ""
log_info "Logs: docker compose logs -f"
