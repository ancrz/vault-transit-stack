#!/usr/bin/env bash
# Start the stack. The first start bootstraps it (scripts/init.sh); later starts only bring the
# containers up: the main store logs in to the KMS with its AppRole and unseals by itself.
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${PROJECT_ROOT}"
[ -f .env ] || { cp .env.example .env; echo "[start] created .env from .env.example"; }
# .env fills only what the environment does not set (a variable on the command line wins).
load_env() {
  [ -f "$1" ] || return 0
  local line key
  while IFS= read -r line || [ -n "${line}" ]; do
    [[ "${line}" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
    key=${BASH_REMATCH[1]}
    [ -n "${!key+x}" ] || export "${key}=${BASH_REMATCH[2]}"
  done < "$1"
}
load_env .env
export HOST_UID="${HOST_UID:-$(id -u)}" HOST_GID="${HOST_GID:-$(id -g)}"
if [ ! -s secrets/main/seal/secret_id ] || [ ! -s secrets/main/init.json ]; then
  exec ./scripts/init.sh
fi
docker compose up -d --wait
./scripts/status.sh
