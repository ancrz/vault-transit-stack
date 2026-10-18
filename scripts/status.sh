#!/usr/bin/env bash
# Seal status of both stores, the AppRole secret_ids' validity is checked by init.sh.
set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for svc in openbao-kms openbao; do
  s=$(docker compose exec -T "${svc}" sh -c 'BAO_ADDR=https://127.0.0.1:8200 BAO_CACERT=/openbao/tls/ca.crt bao status -format=json' 2>/dev/null || true)
  if [ -z "${s}" ]; then echo "${svc}: not running"; continue; fi
  echo "${svc}: $(echo "${s}" | jq -r '"initialized=\(.initialized) sealed=\(.sealed) seal=\(.type) version=\(.version)"')"
done
./scripts/certs.sh --check | sed 's/^/tls: /'
