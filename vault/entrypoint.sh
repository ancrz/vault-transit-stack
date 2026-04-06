#!/bin/sh
set -e

# Generate config from template
envsubst '${VAULT_CONTAINER_LISTEN_PORT} ${VAULT_LOG_LEVEL}' \
  < /vault/config/vault.hcl.template \
  > /vault/config/vault.hcl

# Execute Vault server (PID 1 for clean signal handling)
exec vault server -config=/vault/config/vault.hcl
