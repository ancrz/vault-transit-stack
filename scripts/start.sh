#!/bin/bash
# =============================================================================
# Vault Transit Stack — Startup Script
# =============================================================================
# Usage:
#   ./scripts/start.sh          Start all vault services
#   ./scripts/start.sh --init   First-time setup (vault-a only)
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

# --- Parse flags ---
INIT_MODE=false
for arg in "$@"; do
    case "$arg" in
        --init|-i) INIT_MODE=true ;;
        --help|-h)
            echo "Usage: $0 [--init]"
            echo "  --init, -i  First-time setup: starts only vault-a for initialization"
            echo "  (no flags)  Start all vault services (requires prior initialization)"
            exit 0
            ;;
        *) log_error "Unknown flag: $arg. Use --help for options." ;;
    esac
done

# --- Load environment variables ---
if [ -f "$PROJECT_DIR/.env" ]; then
    set -a
    . "$PROJECT_DIR/.env"
    set +a
    log_info "Environment variables loaded from .env"
else
    log_error ".env file not found. Copy .env.example to .env and configure values."
fi

# --- Validate Docker ---
if ! docker info > /dev/null 2>&1; then
    log_error "Docker is not running or you lack permissions."
fi

# --- Validate required variables ---
REQUIRED_VARS="VAULT_TAG VAULT_A_PORT VAULT_B_PORT HOST_UID HOST_GID"
for var in $REQUIRED_VARS; do
    if [ -z "${!var:-}" ]; then
        log_error "Required variable $var is not defined in .env"
    fi
done

# --- Warn about secrets ---
if [ -z "${VAULT_A_UNSEAL_KEY:-}" ]; then
    log_warn "VAULT_A_UNSEAL_KEY not set. Vault-a will remain sealed after start."
fi

if [ "$INIT_MODE" = false ] && [ -z "${VAULT_B_TRANSIT_TOKEN:-}" ]; then
    log_warn "VAULT_B_TRANSIT_TOKEN not set. Vault-b will fail to configure transit seal."
fi

# --- Start services ---
cd "$PROJECT_DIR"

if [ "$INIT_MODE" = true ]; then
    log_info "INIT MODE: Starting only vault-a for first-time setup..."
    docker compose up -d --build vault-a
    log_info ""
    log_info "Vault-a is starting. Wait for it to become healthy, then follow:"
    log_info "  docs/first-time-setup.md"
    log_info ""
    log_info "  Vault-a UI: http://localhost:${VAULT_A_PORT:-8282}/ui"
    log_info ""
    log_info "After completing setup, run: ./scripts/start.sh (without --init)"
else
    log_info "Starting all vault services..."
    docker compose up -d --build
    log_info ""
    log_info "  Vault-a: http://localhost:${VAULT_A_PORT:-8282}/ui"
    log_info "  Vault-b: http://localhost:${VAULT_B_PORT:-8283}/ui"
fi

log_info ""
log_info "Logs: docker compose logs -f"
