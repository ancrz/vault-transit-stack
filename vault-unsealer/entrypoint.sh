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

log_info "Vault unsealer starting. Target: ${VAULT_ADDR}, poll: ${POLL_INTERVAL}s"

# State tracking to avoid log spam
LAST_STATE=""

# Main loop
while true; do
    # Wait for keys file (first-time: operator creates after vault init)
    if [ ! -f "$UNSEAL_KEYS_FILE" ]; then
        if [ "$LAST_STATE" != "no_keys" ]; then
            log_warn "Waiting for keys file: ${UNSEAL_KEYS_FILE}"
            log_warn "After 'vault operator init', create from: vault-unsealer/keys/vault_keys.json.example"
            LAST_STATE="no_keys"
        fi
        sleep "$POLL_INTERVAL"
        continue
    fi

    # Check seal status
    RESPONSE=$(curl -sf "${VAULT_ADDR}/v1/sys/seal-status" 2>/dev/null) || {
        if [ "$LAST_STATE" != "unreachable" ]; then
            log_warn "Vault unreachable at ${VAULT_ADDR}. Polling..."
            LAST_STATE="unreachable"
        fi
        sleep "$POLL_INTERVAL"
        continue
    }

    INITIALIZED=$(echo "$RESPONSE" | jq -r '.initialized')
    SEALED=$(echo "$RESPONSE" | jq -r '.sealed')
    THRESHOLD=$(echo "$RESPONSE" | jq -r '.t')

    # Not initialized — skip (requires manual operator init)
    if [ "$INITIALIZED" = "false" ]; then
        if [ "$LAST_STATE" != "not_init" ]; then
            log_warn "Vault not initialized. Run: docker exec vault-server vault operator init"
            LAST_STATE="not_init"
        fi
        sleep "$POLL_INTERVAL"
        continue
    fi

    # Already unsealed — all good
    if [ "$SEALED" = "false" ]; then
        if [ "$LAST_STATE" != "unsealed" ]; then
            log_info "Vault is unsealed and operational."
            LAST_STATE="unsealed"
        fi
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
