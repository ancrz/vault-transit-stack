# First-Time Setup Guide

This guide covers the complete initialization sequence for a fresh deployment of the Vault Transit Stack. Follow all steps in order.

---

## Prerequisites

- Docker Engine 24+ with Docker Compose v2+ installed and running
- `.env` file created and configured (see Step 1)
- No existing `vault-a/file/` or `vault-b/file/` data from a prior run

---

## Step 1: Configure Environment

Copy the example file and set the required values:

```bash
cp .env.example .env
```

Edit `.env` and set at minimum:

```bash
HOST_UID=1000        # Your host user ID: id -u
HOST_GID=1000        # Your host group ID: id -g
VAULT_TAG=1.15.4     # Pin to a specific Vault version
VAULT_A_PORT=8282    # Host port for vault-a UI
VAULT_B_PORT=8283    # Host port for vault-b UI
```

Leave `VAULT_A_UNSEAL_KEY` and `VAULT_B_TRANSIT_TOKEN` empty for now — they are populated during this guide.

---

## Step 2: Start vault-a Only (Init Mode)

```bash
./scripts/start.sh --init
```

This builds and starts only vault-a. vault-b is not started yet. Wait until vault-a is running:

```bash
docker compose logs -f vault-a
# Wait for: "core: vault is unsealed" or "core: post-unseal setup complete"
# Or check status:
docker exec -e VAULT_ADDR='http://127.0.0.1:8200' vault-a-server vault status
```

vault-a will be **sealed** at this point (no unseal key set yet). That is expected.

---

## Step 3: Initialize vault-a

Run initialization with 1 key share and threshold of 1 (adjust if you need Shamir multi-party):

```bash
docker exec \
  -e VAULT_ADDR='http://127.0.0.1:8200' \
  vault-a-server \
  vault operator init \
    -key-shares=1 \
    -key-threshold=1 \
    -format=json
```

**Save the output.** It contains the unseal key and root token. Example output:

```json
{
  "unseal_keys_b64": ["abc123..."],
  "root_token": "hvs.XXXXXXXXXXXX"
}
```

Store them securely (password manager, encrypted file). Do **not** commit them.

---

## Step 4: Save Unseal Key and Unseal vault-a

Set `VAULT_A_UNSEAL_KEY` in `.env`:

```bash
# Edit .env and set:
VAULT_A_UNSEAL_KEY=abc123...   # The value from unseal_keys_b64[0]
```

Now unseal vault-a manually for this session:

```bash
docker exec \
  -e VAULT_ADDR='http://127.0.0.1:8200' \
  vault-a-server \
  vault operator unseal YOUR_UNSEAL_KEY_HERE
```

Verify vault-a is unsealed:

```bash
docker exec \
  -e VAULT_ADDR='http://127.0.0.1:8200' \
  vault-a-server \
  vault status
# Sealed: false
```

---

## Step 5: Configure Transit Backend on vault-a

Use the root token from Step 3:

```bash
# Enable the transit secrets engine
docker exec \
  -e VAULT_ADDR='http://127.0.0.1:8200' \
  -e VAULT_TOKEN='hvs.XXXXXXXXXXXX' \
  vault-a-server \
  vault secrets enable transit

# Create the autounseal encryption key
docker exec \
  -e VAULT_ADDR='http://127.0.0.1:8200' \
  -e VAULT_TOKEN='hvs.XXXXXXXXXXXX' \
  vault-a-server \
  vault write -f transit/keys/autounseal
```

---

## Step 6: Create Autounseal Policy and Generate Transit Token

Apply the autounseal policy (already present in the config):

```bash
docker exec \
  -e VAULT_ADDR='http://127.0.0.1:8200' \
  -e VAULT_TOKEN='hvs.XXXXXXXXXXXX' \
  vault-a-server \
  vault policy write autounseal /vault/config/autounseal-policy.hcl
```

Generate a long-lived token scoped to this policy:

```bash
docker exec \
  -e VAULT_ADDR='http://127.0.0.1:8200' \
  -e VAULT_TOKEN='hvs.XXXXXXXXXXXX' \
  vault-a-server \
  vault token create \
    -policy=autounseal \
    -period=8760h \
    -format=json
```

The `-period=8760h` sets a renewable 1-year period. Note the `client_token` value from the output.

---

## Step 7: Save Transit Token to .env

Edit `.env` and set:

```bash
VAULT_B_TRANSIT_TOKEN=hvs.YYYYYYYYYYYY   # The client_token from Step 6
```

---

## Step 8: Start the Full Stack

```bash
./scripts/start.sh
```

This restarts vault-a (with `VAULT_A_UNSEAL_KEY` now set, so it auto-unseals) and starts vault-b (which auto-unseals via vault-a's transit engine).

Wait for both services to become healthy:

```bash
docker compose ps
# vault-a-server   running (healthy)
# vault-b-server   running (healthy)
```

---

## Step 9: Initialize vault-b

vault-b is running but uninitialized. Initialize it:

```bash
docker exec \
  -e VAULT_ADDR='http://127.0.0.1:8200' \
  vault-b-server \
  vault operator init
```

vault-b uses transit auto-unseal, so the output will include **recovery keys** (not standard unseal keys). Save them securely — they are needed for disaster recovery but not for normal operation.

---

## Step 10: Verify Auto-Unseal Works

Restart vault-b to confirm auto-unseal works without manual intervention:

```bash
docker compose restart vault-b
```

Wait ~30 seconds, then check:

```bash
docker exec \
  -e VAULT_ADDR='http://127.0.0.1:8200' \
  vault-b-server \
  vault status
# Sealed: false
# Storage Type: file
# Seal Type: transit
```

If vault-b reports `Sealed: false` after restart, auto-unseal is working correctly.

---

## Post-Setup Summary

| Item | Where to find it |
|------|-----------------|
| vault-a UI | http://localhost:8282/ui |
| vault-b UI | http://localhost:8283/ui |
| vault-a unseal key | `.env` → `VAULT_A_UNSEAL_KEY` |
| vault-a root token | Saved securely in Step 3 |
| vault-b transit token | `.env` → `VAULT_B_TRANSIT_TOKEN` |
| vault-b recovery keys | Saved securely in Step 9 |
| vault-b root token | Generated in Step 9 output |

For architecture details, see [vault-architecture.md](vault-architecture.md).
