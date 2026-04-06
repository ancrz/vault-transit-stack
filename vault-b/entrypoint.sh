#!/bin/sh
set -e

# Substitute environment variables into config template
envsubst '${VAULT_B_TRANSIT_TOKEN} ${VAULT_TRANSIT_KEY_NAME} ${VAULT_TRANSIT_MOUNT_PATH}' \
  < /vault/config/config.hcl.template \
  > /vault/config/vault.hcl

# Execute Vault server
exec vault server -config=/vault/config/vault.hcl
