# Vault Auto-Unseal — Ansible Playbook

Automates unsealing a HashiCorp Vault instance using Shamir key shares stored
in an Ansible Vault-encrypted file. Designed for single-server bare-metal
deployments where transit auto-unseal adds no availability benefit.

---

## Prerequisites

- **ansible-core 2.15+**

  ```bash
  # via pip (recommended — version control)
  pip install ansible-core

  # via apt (Ubuntu/Debian)
  sudo apt install ansible
  ```

- Vault container running and reachable at the address in `vault_keys.yml`
- Unseal keys from `vault operator init` stored in `ansible/vars/vault_keys.yml`

---

## Quick Start

**Step 1 — Create your keys file from the example:**

```bash
cd ansible/vars
cp vault_keys.yml.example vault_keys.yml
```

Edit `vault_keys.yml` and replace the placeholder values with the real unseal
keys from `vault operator init -format=json`.

**Step 2 — Encrypt the keys file with Ansible Vault:**

```bash
ansible-vault encrypt vault_keys.yml
# Enter and confirm a strong password when prompted
```

**Step 3 — Run the unseal playbook:**

```bash
cd ansible
ansible-playbook vault-unseal.yml --ask-vault-pass
```

---

## Usage Examples

**Manual unseal (interactive password prompt):**

```bash
ansible-playbook vault-unseal.yml --ask-vault-pass
```

**With a password file (non-interactive, suitable for automation):**

```bash
ansible-playbook vault-unseal.yml --vault-password-file ~/.vault_pass
```

Store the Ansible Vault password in `~/.vault_pass` (mode `600`):

```bash
echo 'your-ansible-vault-password' > ~/.vault_pass
chmod 600 ~/.vault_pass
```

**Dry run — check status without applying keys:**

```bash
ansible-playbook vault-unseal.yml --ask-vault-pass --check
```

Note: `--check` mode will not apply unseal keys but will still query the
seal-status endpoint and report the current state.

---

## Automated Unseal on Reboot

### Option A: Cron (simple)

Add to root crontab (`sudo crontab -e`):

```
@reboot sleep 15 && cd /path/to/vault-transit-stack/ansible && ansible-playbook vault-unseal.yml --vault-password-file ~/.vault_pass >> /var/log/vault-unseal.log 2>&1
```

The `sleep 15` allows Docker to start the Vault container before the playbook runs.

### Option B: Systemd timer (recommended for production)

Create `/etc/systemd/system/vault-unseal.service`:

```ini
[Unit]
Description=Vault Auto-Unseal
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
User=YOUR_USER
WorkingDirectory=/path/to/vault-transit-stack/ansible
ExecStartPre=/bin/sleep 15
ExecStart=/usr/bin/ansible-playbook vault-unseal.yml --vault-password-file /home/YOUR_USER/.vault_pass
StandardOutput=journal
StandardError=journal
```

Create `/etc/systemd/system/vault-unseal.timer`:

```ini
[Unit]
Description=Run Vault Auto-Unseal after boot

[Timer]
OnBootSec=30s
Unit=vault-unseal.service

[Install]
WantedBy=timers.target
```

Enable and start:

```bash
sudo systemctl daemon-reload
sudo systemctl enable vault-unseal.timer
sudo systemctl start vault-unseal.timer
```

Check timer status: `systemctl status vault-unseal.timer`
Check last run: `journalctl -u vault-unseal.service -n 50`

---

## Variables Reference

Variables are defined in `vars/vault_keys.yml` (Ansible Vault encrypted).

| Variable | Description | Example |
|----------|-------------|---------|
| `vault_addr` | Vault HTTP API address | `http://127.0.0.1:8200` |
| `vault_unseal_keys` | List of Shamir unseal key shares | `["key1", "key2", "key3"]` |

The playbook reads `t` (threshold) from the seal-status response and applies
only `vault_unseal_keys[:t]` — providing more keys than needed is safe and
allows the file to store all 5 shares while only submitting 3.

---

## Security Notes

- **Never commit `vault_keys.yml` unencrypted.** The `.gitignore` at the
  project root excludes it. Verify with `git status` before any push.
- **Store the Ansible Vault password in a password manager** (Bitwarden,
  1Password, etc.), not only in `~/.vault_pass`.
- **Back up unseal keys in a separate secure location** from the Ansible Vault
  password. If both are lost simultaneously, the vault cannot be unsealed.
- The playbook uses `no_log: true` on the unseal key submission task to prevent
  key material appearing in Ansible output or logs.
- Restrict `~/.vault_pass` to mode `600` and owned by the operator user.

---

## Troubleshooting

**Connection refused / Vault is unreachable**

The container is not running or not yet healthy. Check:

```bash
docker compose ps
docker compose logs vault
```

If the container is starting up, wait for it to finish and retry.

**Vault is still sealed after applying keys**

The keys in `vault_keys.yml` do not match the vault's seal configuration.
This happens if vault was re-initialized. Decrypt and verify the keys:

```bash
ansible-vault view vault_keys.yml
```

Then compare against the output of:

```bash
docker exec vault-server vault status
```

**Vault is not initialized**

The vault data directory is empty or vault has never been initialized.
Follow the first-time setup guide at `docs/single-vault-setup.md`.

**ansible-vault: command not found**

Install ansible-core: `pip install ansible-core`
