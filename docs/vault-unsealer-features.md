# Vault Unsealer Sidecar — Feature Coverage

The `vault-unsealer` is a lightweight Docker sidecar (Alpine + curl + jq) that
monitors HashiCorp Vault's seal status and automatically applies unseal keys
when needed. It runs alongside the vault container in the same Docker Compose stack.

## Architecture

```
docker-compose.yml
  │
  ├── vault (HashiCorp Vault 1.15.4, Shamir seal)
  │     Port: localhost:${VAULT_PORT}
  │     restart: unless-stopped
  │
  └── vault-unsealer (Alpine sidecar)
        Polls: http://vault-server:8200/v1/sys/seal-status
        Keys from: /run/secrets/keys/vault_keys.json (bind mount)
        restart: unless-stopped
```

## Covered Scenarios

### Lifecycle Events

| Scenario | Behavior | Recovery Time |
|----------|----------|---------------|
| **Fresh start** (no data, no keys file) | Logs warning once, polls silently for keys file to appear | Instant once file created |
| **Fresh start** (no data, keys file exists) | Detects vault not initialized, logs warning once, polls silently | Instant once `vault operator init` is run |
| **Normal operation** (unsealed) | Logs "unsealed and operational" once, then silent polling | N/A |
| **Container restart** (`docker restart vault`) | Detects sealed state within poll interval, applies keys | ≤ poll interval (default 10s) |
| **Container crash** (`docker kill vault`) | Docker restarts vault → unsealer detects sealed → unseals | ≤ poll interval + Docker restart time |
| **Host reboot** | Docker daemon restarts both containers → same as crash recovery | ≤ poll interval + boot time |
| **Unsealer container restart** | Docker restarts it, re-reads keys file, resumes polling | ≤ poll interval |
| **Network interruption** between containers | Logs "unreachable" once, polls silently until connectivity returns | Automatic on reconnect |

### Input Validation

| Scenario | Behavior |
|----------|----------|
| **Keys file missing** | Logs warning once with instructions, polls for file to appear |
| **Keys file is invalid JSON** | Logs error once ("not valid JSON"), polls for file to be fixed |
| **Keys file has empty array** (`vault_unseal_keys: []`) | Logs error once ("no unseal keys"), polls for file update |
| **Keys file missing `vault_unseal_keys` field** | Logs error once, polls for fix |
| **Fewer keys than threshold** (e.g., 2 keys but threshold is 3) | Logs error once ("have 2, need 3"), polls for file update |
| **Placeholder keys** (contains "REPLACE_WITH") | Logs error ("placeholder or empty"), does not attempt unseal |
| **Empty/null key value** in array | Logs error, stops applying keys for this cycle |
| **Keys file deleted while running** | Next cycle detects missing file, reverts to "waiting for keys" state |
| **Keys file replaced with new content** | Next cycle reads new file, applies new keys |

### API Response Validation

| Scenario | Behavior |
|----------|----------|
| **Vault API returns unexpected JSON** (missing `initialized`/`sealed`) | Logs error once ("missing field"), polls for vault to respond correctly |
| **Vault API returns non-JSON** | curl fails (non-zero exit), treated as unreachable |
| **Vault API returns 503** (sealed) | Handled — curl with `-sf` still captures response body |
| **Vault returns `sealed: null`** | Validated as bad response, logged, retry |

### Unseal Operation

| Scenario | Behavior |
|----------|----------|
| **Successful unseal** (all keys valid) | Logs "unsealed successfully after N key(s)" |
| **Partial unseal** (some keys applied, then failure) | Logs error on failed key, retries ALL keys next cycle (Vault accepts duplicate key submissions) |
| **Wrong keys** (valid base64 but not from this vault) | Vault API rejects, logged as failed, retries next cycle |
| **Vault re-sealed externally** (`vault operator seal`) | Next poll detects sealed, re-applies keys automatically |

## Log Behavior

The unsealer uses **state tracking** to prevent log spam. Each state change is
logged once, then the unsealer polls silently until the state changes again.

| State | Log Level | Message | Frequency |
|-------|-----------|---------|-----------|
| Starting | INFO | "Vault unsealer starting. Target: ..., poll: ..." | Once at startup |
| No keys file | WARN | "Waiting for keys file: ..." | Once per state transition |
| Invalid JSON | ERROR | "Keys file is not valid JSON" | Once per state transition |
| Empty keys | ERROR | "Keys file has no unseal keys" | Once per state transition |
| Unreachable | WARN | "Vault unreachable at ... Polling..." | Once per state transition |
| Not initialized | WARN | "Vault not initialized. Run: docker exec ..." | Once per state transition |
| Unsealed | INFO | "Vault is unsealed and operational." | Once per state transition |
| Sealed → unsealing | INFO | "Vault is sealed. Applying unseal keys..." | Every seal event |
| Unseal success | INFO | "Vault unsealed successfully after N key(s)." | Every successful unseal |
| Unseal failure | ERROR | "Vault still sealed after applying N/T keys." | Every failed attempt |
| Insufficient keys | ERROR | "Not enough keys: have N, need T." | Once per state transition |
| Placeholder key | ERROR | "Key N is a placeholder or empty." | Every unseal attempt with placeholders |

## Configuration

All configuration via environment variables in `.env`:

| Variable | Default | Description |
|----------|---------|-------------|
| `UNSEALER_POLL_INTERVAL` | `10` | Seconds between seal status checks |
| `UNSEALER_KEYS_FILE` | `/run/secrets/keys/vault_keys.json` | Path to keys file inside container |
| `UNSEALER_MEM_LIMIT` | `64m` | Container memory limit |
| `UNSEALER_MEM_RESERVATION` | `32m` | Container memory reservation |

## Keys File Format

```json
{
  "vault_unseal_keys": [
    "base64_key_1",
    "base64_key_2",
    "base64_key_3"
  ]
}
```

- Only `threshold` number of keys needed (default: 3 of 5)
- Keys are base64-encoded Shamir key shares from `vault operator init -format=json`
- File location: `vault-unsealer/keys/vault_keys.json` (gitignored)
- Template: `vault-unsealer/keys/vault_keys.json.example`

## Security Considerations

| Aspect | Status |
|--------|--------|
| Keys at rest on disk | Keys file is on the Docker host filesystem. An attacker with root access can read it. This is a documented tradeoff — see docs/legacy-transit/ for the architectural analysis. |
| Keys in container memory | curl passes keys via command-line argument (visible in `/proc`). The container runs as non-root user `unsealer` (uid 1000). |
| Keys in Docker inspect | Keys are NOT in environment variables — they are in a bind-mounted file. `docker inspect` does not expose them. |
| Keys in logs | Keys are NEVER logged. Only key index numbers appear in logs. |
| Keys file permissions | Should be `chmod 600` (owner read/write only). |
| Git safety | `vault_keys.json` is in `.gitignore`. Only `.json.example` with placeholders is committed. |
| Network exposure | Unsealer communicates with vault over Docker internal network only (not exposed to host). |

## Limitations

1. **No HSM/TPM integration** — keys are software-only, stored on filesystem
2. **No key rotation** — if vault is rekeyed, operator must manually update keys file
3. **No alerting** — logs errors but does not send notifications (integrate with Docker logging driver for alerts)
4. **Single vault only** — designed for one vault instance, not HA clusters
5. **No TLS** — vault-to-unsealer communication is unencrypted over Docker network (acceptable for same-host containers)
