# Single Vault — First-Time Setup Guide

This guide walks through initializing a fresh Vault instance and configuring
the sidecar-managed auto-unseal for the single-vault stack.

---

## Prerequisites

| Requirement | Minimum Version | Check |
|-------------|----------------|-------|
| Docker Engine | 24.0+ | `docker --version` |
| Docker Compose | v2.0+ | `docker compose version` |

---

## Step 1: Configure Environment

Copy the example environment file and adjust for your host:

```bash
cp .env.example .env
```

Set `HOST_UID` and `HOST_GID` to match your user:

```bash
id -u   # HOST_UID
id -g   # HOST_GID
```

Edit `.env` with these values. All other defaults are suitable for a local
single-server deployment.

---

## Step 2: Start Vault

```bash
./scripts/start.sh
```

The container will build and start. Vault launches in a **sealed** state — this
is expected. The UI will be available at `http://localhost:8200/ui` but will
prompt for unsealing/initialization.

Confirm the container is running:

```bash
docker compose ps
docker compose logs vault
```

---

## Step 3: Initialize Vault

Run the initialization command inside the container. This generates the Shamir
key shares and the root token. **Only run this once per fresh data directory.**

```bash
docker exec vault-server vault operator init \
  -key-shares=5 -key-threshold=3 -format=json
```

This outputs a JSON object. Example structure (values are illustrative):

```json
{
  "unseal_keys_b64": [
    "key1base64...",
    "key2base64...",
    "key3base64...",
    "key4base64...",
    "key5base64..."
  ],
  "unseal_keys_hex": [...],
  "unseal_shares": 5,
  "unseal_threshold": 3,
  "recovery_keys_b64": [],
  "root_token": "hvs.XXXXXXXXXXXXXXXXXXXXXXXX"
}
```

---

## Step 4: Save Output Securely

**This output is shown only once.** Store it immediately in a secure location
before proceeding.

- Save all 5 unseal keys and the root token to a password manager.
- Do NOT store them in `.env`, in git, or in plaintext files on disk.
- Losing more than 2 unseal keys (with threshold=3) means the vault cannot
  be unsealed and all data is permanently inaccessible.

---

## Step 5: Configure Unseal Keys

The `vault-unsealer` sidecar is the primary unseal mechanism. It polls the
seal-status endpoint and applies keys automatically every time Vault starts sealed.

```bash
cd vault-unsealer/keys
cp vault_keys.json.example vault_keys.json
```

Edit `vault_keys.json` and replace the placeholder values with the threshold
number of unseal keys from Step 3 (3 keys if using the default threshold=3):

```json
{
  "vault_unseal_keys": [
    "your-actual-unseal-key-1",
    "your-actual-unseal-key-2",
    "your-actual-unseal-key-3"
  ]
}
```

**Security note:** `vault_keys.json` is gitignored and stored in plaintext.
Restrict file permissions and keep it on a trusted host only:

```bash
chmod 600 vault-unsealer/keys/vault_keys.json
```

Once the file is in place, restart the stack and the sidecar will auto-unseal
within the next poll interval (default: 10 seconds).

> **Alternative:** For manual or remote unsealing (e.g., headless hosts without
> Docker, or operator-triggered unseal), an Ansible playbook is available in
> [docs/ansible-alternative/](ansible-alternative/). It is not required for
> normal operation.

---

## Step 6: Unseal Vault

The sidecar starts automatically with the stack and will unseal Vault within
one poll interval. Confirm by watching logs:

```bash
docker compose logs -f vault-unsealer
```

Expected output when unsealing completes:

```
[INFO]  Vault is sealed. Applying unseal keys (threshold: 3)...
[INFO]  Vault unsealed successfully after 3 key(s).
```

---

## Step 7: Verify

Check vault status from inside the container:

```bash
docker exec vault-server vault status
```

Expected output includes `Sealed: false`. The vault is operational.

Access the UI at `http://localhost:8200/ui` and log in with the root token
from Step 3.

---

## Step 8: (Optional) Auto-Unseal on Reboot

The sidecar handles unseal automatically on every `docker compose up`, including
after host reboots when Docker is configured to start on boot (the default on
most Linux distributions with Docker installed via the official package).

For remote or operator-triggered unseal via Ansible, see
[docs/ansible-alternative/README.md](ansible-alternative/README.md) for cron
and systemd timer instructions.

---

## Migration from Transit Stack

If migrating from the dual-vault transit auto-unseal configuration, note the
following breaking changes:

| Item | Transit Stack | Single Vault |
|------|--------------|-------------|
| Application vault container | `vault-b-server` | `vault-server` |
| Application vault port | `8283` | `8200` |
| Unseal method | Transit auto-unseal via vault-a | Sidecar Shamir unseal |
| `.env` key shares | `VAULT_KEY_SHARES=1` | `VAULT_KEY_SHARES=5` |
| Data directory | `./vault-b/file/` | `./vault/file/` |

**Vault data must be re-initialized.** The transit seal wraps the vault's
encryption key using vault-a's transit engine. There is no migration path
for sealed data from a transit-unsealed vault to a Shamir-unsealed vault —
export any secrets before decommissioning vault-b.

### Environment variable mapping

| Transit Stack | Single Vault |
|--------------|-------------|
| `VAULT_B_PORT` | `VAULT_PORT` |
| `VAULT_B_CONTAINER_NAME` | `VAULT_CONTAINER_NAME` |
| `VAULT_B_MEM_LIMIT` | `VAULT_MEM_LIMIT` |
| `VAULT_B_MEM_RESERVATION` | `VAULT_MEM_RESERVATION` |
| `VAULT_B_TRANSIT_TOKEN` | (removed — not applicable) |
| `VAULT_A_UNSEAL_KEY` | (removed — managed by sidecar) |

---

## Security Best Practices

- **Root token**: After initial setup, create an admin policy with limited
  scope and revoke the root token. Regenerate it only when needed via
  `vault operator generate-root`.
- **TLS**: The default configuration has TLS disabled (`tls_disable = true`).
  For production or any network-exposed deployment, configure TLS by updating
  `vault/config/vault.hcl.template` with a certificate and key.
- **Firewall**: The port binding `127.0.0.1:8200` restricts access to
  localhost. Use a reverse proxy (nginx, Caddy) with TLS termination for
  external access.
- **IPC_LOCK**: The container runs with `IPC_LOCK` capability to prevent
  Vault's memory from being swapped to disk. This is the correct production
  posture.
- **Audit log**: Enable audit logging after initialization:
  ```bash
  vault audit enable file file_path=/vault/logs/audit.log
  ```
