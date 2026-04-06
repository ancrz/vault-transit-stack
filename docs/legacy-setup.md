# Portainer and Vault Deployment with Auto-Unseal

This directory contains the Docker Compose setup for deploying Portainer and two HashiCorp Vault instances (`vault-a` and `vault-b`).

The environment is configured for a high-availability setup where `vault-a` acts as the "support" instance providing an auto-unseal mechanism for `vault-b` using its `transit` secrets engine.

## 1. Initial Configuration

Before starting, you must create a `.env` file.

```bash
cp .env.example .env
```

This file contains all the necessary environment variables for ports, versions, and user/group IDs. If Portainer fails to start due to permission errors with `/var/run/docker.sock`, ensure the `DOCKER_GID` in the `.env` file matches the GID of the `docker` group on your host machine. You can find it by running `getent group docker`.

## 2. First-Time Setup: Configuring Vault Auto-Unseal

This process must be followed sequentially to ensure `vault-b` can communicate with a fully configured `vault-a`.

### Step 2.1: Start and Initialize `vault-a`

Start vault-a alone (without vault-b) so it can be initialized before vault-b tries to connect.

```bash
docker compose up -d vault-a
```

Wait for vault-a to be running, then initialize it:

```bash
docker exec -e VAULT_ADDR='http://127.0.0.1:8200' vault-a-server \
  vault operator init -key-shares=1 -key-threshold=1 -format=json \
  > vault_keys.txt
```

This saves the unseal key and root token to `vault_keys.txt`. **Keep this file secure.**

Extract and unseal vault-a:

```bash
# Get the unseal key
UNSEAL_KEY=$(jq -r '.unseal_keys_b64[0]' vault_keys.txt)
ROOT_TOKEN=$(jq -r '.root_token' vault_keys.txt)

# Unseal vault-a
docker exec -e VAULT_ADDR='http://127.0.0.1:8200' vault-a-server \
  vault operator unseal "$UNSEAL_KEY"
```

### Step 2.2: Configure the Transit Secrets Engine on `vault-a`

Login and enable the transit engine:

```bash
docker exec -e VAULT_ADDR='http://127.0.0.1:8200' -e VAULT_TOKEN="$ROOT_TOKEN" vault-a-server \
  vault secrets enable transit

docker exec -e VAULT_ADDR='http://127.0.0.1:8200' -e VAULT_TOKEN="$ROOT_TOKEN" vault-a-server \
  vault write -f transit/keys/autounseal
```

### Step 2.3: Create the Auto-Unseal Policy

```bash
docker exec -e VAULT_ADDR='http://127.0.0.1:8200' -e VAULT_TOKEN="$ROOT_TOKEN" vault-a-server \
  vault policy write autounseal /vault/config/autounseal-policy.hcl
```

### Step 2.4: Generate the Transit Token for `vault-b`

```bash
docker exec -e VAULT_ADDR='http://127.0.0.1:8200' -e VAULT_TOKEN="$ROOT_TOKEN" vault-a-server \
  vault token create -policy=autounseal -period=768h -format=json \
  | jq -r '.auth.client_token'
```

Save this token to your `.env` as `VAULT_B_TRANSIT_TOKEN`.

### Step 2.5: Start `vault-b`

```bash
docker compose up -d vault-b
```

vault-b will read `VAULT_B_TRANSIT_TOKEN` from the environment and use it to auto-unseal via vault-a's transit engine.

### Step 2.6: Initialize `vault-b`

```bash
docker exec -e VAULT_ADDR='http://127.0.0.1:8200' vault-b-server \
  vault operator init
```

vault-b uses transit auto-unseal, so no manual unseal key is needed on subsequent restarts — vault-a handles it.

### Step 2.7: Save Keys and Restart with Unseal Key

Update `.env` with `VAULT_A_UNSEAL_KEY` so vault-a auto-unseals on container restart. Then update the stack:

```bash
docker compose up -d
```

## 3. Service Lifecycle and Purpose

- **vault-a**: Runs continuously. Provides the transit secrets engine that vault-b uses for auto-unseal. Must always be healthy before vault-b starts.
- **vault-b**: The primary secrets store. Auto-unseals via vault-a's transit engine on every startup. In the original monolith, vault-a's entrypoint would stop vault-b after unsealing (co-dependency); this pattern has been removed in the current stack.

## 4. Managing the Environment

```bash
# Start all services
docker compose up -d

# Stop all services (data preserved)
docker compose down

# Stop and destroy all data (irreversible)
docker compose down -v

# View logs
docker compose logs -f vault-a
docker compose logs -f vault-b

# Reset vault-a data (forces re-initialization)
docker compose down
rm -rf vault-a/file/*
docker compose up -d
```

---

## Changes from Legacy (vault-transit-stack)

This document preserves the original setup guide from the monolith `portainer/` project.
The following changes were made during the split:

1. **vault-a no longer stops vault-b.** The original `entrypoint.sh` for vault-a contained
   `docker stop vault-b-server` after unsealing. This co-dependency has been removed.
   Both vault instances now run independently and persistently.

2. **Portainer removed.** Portainer is now in its own project: `portainer-management-stack/`.

3. **Hardcoded token removed.** vault-b's config.hcl had a hardcoded transit token.
   This is now a template (`config.hcl.template`) with `${VAULT_B_TRANSIT_TOKEN}`
   resolved at container startup via `envsubst`.

4. **External networks removed.** `p-net` and `shared-vault-net` replaced with a
   single internal `vault-internal` network.

5. **UID/GID renamed.** `UID` and `GID` renamed to `HOST_UID` and `HOST_GID` to
   avoid collision with POSIX shell builtins.

6. **Resource limits added.** Memory limits and reservations configured via env vars.

7. **Docker socket removed from vault-a.** vault-a no longer has access to the Docker
   socket (was only needed for stopping vault-b).
