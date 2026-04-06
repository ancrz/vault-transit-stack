#!/bin/sh
set -e

# =============================================================================
# Vault Unsealer — Sidecar Entrypoint
# Polls vault seal status and auto-unseals when needed
# =============================================================================

VAULT_ADDR="${VAULT_ADDR:-http://vault-server:8200}"
POLL_INTERVAL="${POLL_INTERVAL:-10}"
UNSEAL_KEYS_FILE="${UNSEAL_KEYS_FILE:-/run/secrets/vault_keys.json}"

log_info()  { echo "[$(date -Iseconds)] [INFO]  $1"; }
log_warn()  { echo "[$(date -Iseconds)] [WARN]  $1"; }
log_error() { echo "[$(date -Iseconds)] [ERROR] $1"; }

# Wait for vault to be reachable
log_info "Vault unsealer starting. Target: ${VAULT_ADDR}"
log_info "Poll interval: ${POLL_INTERVAL}s"

# Validate keys file exists
if [ ! -f "$UNSEAL_KEYS_FILE" ]; then
    log_error "Unseal keys file not found: ${UNSEAL_KEYS_FILE}"
    log_error "Create it from the example: vault-unsealer/keys/vault_keys.json.example"
    exit 1
fi

# Main loop
while true; do
    # Check seal status
    RESPONSE=$(curl -sf "${VAULT_ADDR}/v1/sys/seal-status" 2>/dev/null) || {
        log_warn "Vault unreachable at ${VAULT_ADDR}. Retrying in ${POLL_INTERVAL}s..."
        sleep "$POLL_INTERVAL"
        continue
    }

    INITIALIZED=$(echo "$RESPONSE" | jq -r '.initialized')
    SEALED=$(echo "$RESPONSE" | jq -r '.sealed')
    THRESHOLD=$(echo "$RESPONSE" | jq -r '.t')

    # Not initialized — skip (requires manual operator init)
    if [ "$INITIALIZED" = "false" ]; then
        log_warn "Vault not initialized. Manual init required. Retrying in ${POLL_INTERVAL}s..."
        sleep "$POLL_INTERVAL"
        continue
    fi

    # Already unsealed — all good
    if [ "$SEALED" = "false" ]; then
        sleep "$POLL_INTERVAL"
        continue
    fi

    # Sealed — apply unseal keys
    log_info "Vault is sealed. Applying unseal keys (threshold: ${THRESHOLD})..."

    KEYS_APPLIED=0
    TOTAL_KEYS=$(jq -r '.vault_unseal_keys | length' "$UNSEAL_KEYS_FILE")
    # Initialize so the post-loop check is always defined
    STILL_SEALED="true"

    for i in $(seq 0 $((THRESHOLD - 1))); do
        if [ "$i" -ge "$TOTAL_KEYS" ]; then
            log_error "Not enough keys in file. Need ${THRESHOLD}, have ${TOTAL_KEYS}."
            break
        fi

        KEY=$(jq -r ".vault_unseal_keys[$i]" "$UNSEAL_KEYS_FILE")

        RESULT=$(curl -sf -X PUT \
            -H "Content-Type: application/json" \
            -d "{\"key\": \"${KEY}\"}" \
            "${VAULT_ADDR}/v1/sys/unseal" 2>/dev/null) || {
            log_error "Failed to apply unseal key $((i + 1)). Retrying next cycle."
            break
        }

        STILL_SEALED=$(echo "$RESULT" | jq -r '.sealed')
        KEYS_APPLIED=$((KEYS_APPLIED + 1))

        if [ "$STILL_SEALED" = "false" ]; then
            log_info "Vault unsealed successfully after ${KEYS_APPLIED} key(s)."
            break
        fi
    done

    # Verify final state
    if [ "$STILL_SEALED" = "true" ]; then
        log_error "Vault still sealed after applying ${KEYS_APPLIED} keys. Check keys file."
    fi

    sleep "$POLL_INTERVAL"
done
