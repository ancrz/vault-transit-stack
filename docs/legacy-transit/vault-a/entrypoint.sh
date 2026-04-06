#!/bin/sh
set -e

# 1. Generate config from template
envsubst '${VAULT_CONTAINER_LISTEN_PORT} ${VAULT_LOG_LEVEL}' \
  < /vault/config/vault.hcl.template \
  > /vault/config/vault.hcl

# 2. Start Vault server in background
vault server -config=/vault/config/vault.hcl &
VAULT_PID=$!
sleep 3

# 3. Attempt auto-unseal using stored key
if [ -n "$VAULT_A_UNSEAL_KEY" ]; then
  echo "INFO: Attempting to unseal Vault-a..."
  if vault operator unseal "$VAULT_A_UNSEAL_KEY" > /dev/null; then
    echo "SUCCESS: Vault-a unsealed successfully."
  else
    echo "ERROR: Failed to unseal Vault-a. It will remain sealed."
    wait $VAULT_PID
    exit 1
  fi
else
  echo "WARNING: VAULT_A_UNSEAL_KEY not set. Vault-a will remain sealed."
fi

# 4. Keep container alive
wait $VAULT_PID
