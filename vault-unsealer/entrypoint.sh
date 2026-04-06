#!/bin/sh
set -e

# =============================================================================
# Vault Unsealer — Sidecar Entrypoint
# Polls vault seal status and auto-unseals when needed
# =============================================================================

VAULT_ADDR="${VAULT_ADDR:-http://vault-server:8200}"
POLL_INTERVAL="${POLL_INTERVAL:-10}"
UNSEAL_KEYS_FILE="${UNSEAL_KEYS_FILE:-/run/secrets/keys/vault_keys.json}"

log_info()  { echo "[$(date -Iseconds)] [INFO]  $1"; }
log_warn()  { echo "[$(date -Iseconds)] [WARN]  $1"; }
log_error() { echo "[$(date -Iseconds)] [ERROR] $1"; }

log_info "Vault unsealer starting. Target: ${VAULT_ADDR}, poll: ${POLL_INTERVAL}s"

# State tracking to avoid log spam
LAST_STATE=""

# --- Validation helpers ---

validate_keys_file() {
    # Check JSON is valid
    if ! jq empty "$UNSEAL_KEYS_FILE" 2>/dev/null; then
        if [ "$LAST_STATE" != "bad_json" ]; then
            log_error "Keys file is not valid JSON: ${UNSEAL_KEYS_FILE}"
            LAST_STATE="bad_json"
        fi
        return 1
    fi

    # Check vault_unseal_keys exists and is an array
    KEY_COUNT=$(jq -r '.vault_unseal_keys | length' "$UNSEAL_KEYS_FILE" 2>/dev/null)
    if [ -z "$KEY_COUNT" ] || [ "$KEY_COUNT" = "null" ] || [ "$KEY_COUNT" -eq 0 ] 2>/dev/null; then
        if [ "$LAST_STATE" != "empty_keys" ]; then
            log_error "Keys file has no unseal keys (vault_unseal_keys is empty or missing)"
            LAST_STATE="empty_keys"
        fi
        return 1
    fi

    return 0
}

validate_seal_response() {
    RESPONSE="$1"

    # Check required fields exist
    for field in initialized sealed; do
        VAL=$(echo "$RESPONSE" | jq -r ".$field" 2>/dev/null)
        if [ -z "$VAL" ] || [ "$VAL" = "null" ]; then
            if [ "$LAST_STATE" != "bad_response" ]; then
                log_error "Vault API response missing field: $field"
                LAST_STATE="bad_response"
            fi
            return 1
        fi
    done

    return 0
}

# --- Main loop ---

while true; do
    # 1. Wait for keys file (first-time: operator creates after vault init)
    if [ ! -f "$UNSEAL_KEYS_FILE" ]; then
        if [ "$LAST_STATE" != "no_keys" ]; then
            log_warn "Waiting for keys file: ${UNSEAL_KEYS_FILE}"
            log_warn "After 'vault operator init', create from: vault-unsealer/keys/vault_keys.json.example"
            LAST_STATE="no_keys"
        fi
        sleep "$POLL_INTERVAL"
        continue
    fi

    # 2. Validate keys file structure
    if ! validate_keys_file; then
        sleep "$POLL_INTERVAL"
        continue
    fi

    # 3. Check seal status
    RESPONSE=$(curl -sf "${VAULT_ADDR}/v1/sys/seal-status" 2>/dev/null) || {
        if [ "$LAST_STATE" != "unreachable" ]; then
            log_warn "Vault unreachable at ${VAULT_ADDR}. Polling..."
            LAST_STATE="unreachable"
        fi
        sleep "$POLL_INTERVAL"
        continue
    }

    # 4. Validate API response structure
    if ! validate_seal_response "$RESPONSE"; then
        sleep "$POLL_INTERVAL"
        continue
    fi

    INITIALIZED=$(echo "$RESPONSE" | jq -r '.initialized')
    SEALED=$(echo "$RESPONSE" | jq -r '.sealed')
    THRESHOLD=$(echo "$RESPONSE" | jq -r '.t // 0')

    # 5. Not initialized — skip (requires manual operator init)
    if [ "$INITIALIZED" = "false" ]; then
        if [ "$LAST_STATE" != "not_init" ]; then
            log_warn "Vault not initialized. Run: docker exec vault-server vault operator init"
            LAST_STATE="not_init"
        fi
        sleep "$POLL_INTERVAL"
        continue
    fi

    # 6. Already unsealed — all good
    if [ "$SEALED" = "false" ]; then
        if [ "$LAST_STATE" != "unsealed" ]; then
            log_info "Vault is unsealed and operational."
            LAST_STATE="unsealed"
        fi
        sleep "$POLL_INTERVAL"
        continue
    fi

    # 7. Sealed — validate we have enough keys before attempting
    TOTAL_KEYS=$(jq -r '.vault_unseal_keys | length' "$UNSEAL_KEYS_FILE")
    if [ "$TOTAL_KEYS" -lt "$THRESHOLD" ]; then
        if [ "$LAST_STATE" != "insufficient_keys" ]; then
            log_error "Not enough keys: have ${TOTAL_KEYS}, need ${THRESHOLD}. Update keys file."
            LAST_STATE="insufficient_keys"
        fi
        sleep "$POLL_INTERVAL"
        continue
    fi

    # 8. Apply unseal keys
    log_info "Vault is sealed. Applying unseal keys (threshold: ${THRESHOLD})..."
    LAST_STATE="unsealing"

    KEYS_APPLIED=0
    STILL_SEALED="true"

    for i in $(seq 0 $((THRESHOLD - 1))); do
        KEY=$(jq -r ".vault_unseal_keys[$i]" "$UNSEAL_KEYS_FILE")

        # Validate key is not a placeholder
        if [ -z "$KEY" ] || [ "$KEY" = "null" ] || echo "$KEY" | grep -q "REPLACE_WITH"; then
            log_error "Key $((i + 1)) is a placeholder or empty. Update keys file with real unseal keys."
            break
        fi

        RESULT=$(curl -sf -X PUT \
            -H "Content-Type: application/json" \
            -d "{\"key\": \"${KEY}\"}" \
            "${VAULT_ADDR}/v1/sys/unseal" 2>/dev/null) || {
            log_error "Failed to apply unseal key $((i + 1)). Retrying next cycle."
            break
        }

        STILL_SEALED=$(echo "$RESULT" | jq -r '.sealed // "true"')
        KEYS_APPLIED=$((KEYS_APPLIED + 1))

        if [ "$STILL_SEALED" = "false" ]; then
            log_info "Vault unsealed successfully after ${KEYS_APPLIED} key(s)."
            LAST_STATE="unsealed"
            break
        fi
    done

    # 9. Verify final state
    if [ "$STILL_SEALED" = "true" ] && [ "$KEYS_APPLIED" -gt 0 ]; then
        log_error "Vault still sealed after applying ${KEYS_APPLIED}/${THRESHOLD} keys. Keys may be incorrect."
    fi

    sleep "$POLL_INTERVAL"
done
