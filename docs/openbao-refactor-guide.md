# OpenBao refactor guide

How to move this stack from HashiCorp Vault 1.15.4 with a Shamir-key sidecar to **OpenBao with a transit mini KMS**. The design is already running in **vanguard-control** (remediation R1, 2026-09-30); this guide ports it back.

Why the refactor is needed (license, support, unseal design): [refactor-to-openbao.md](refactor-to-openbao.md).

---

## 1. Target architecture

```mermaid
flowchart LR
    subgraph KMSNET["kms-net (internal)"]
        KMS["openbao-kms<br/>transit engine only<br/>seal: static"]
    end
    subgraph SECNET["secrets-net (internal, fixed subnet)"]
        BAO["openbao<br/>KV v2 stores<br/>seal: transit"]
        A["writer app<br/>AppRole: create/update only"]
        R1["reader app A<br/>AppRole: read mount A"]
        R2["reader app B<br/>AppRole: read mount B"]
    end
    KEY[("static key file<br/>mounted only into the KMS")] --> KMS
    BAO -- "encrypt/decrypt barrier key<br/>(scoped periodic token)" --> KMS
    A -- "write" --> BAO
    R1 -- "read" --> BAO
    R2 -- "read" --> BAO
```

| Piece | Today (this stack) | After |
|---|---|---|
| Image | `hashicorp/vault:1.15.4` (BSL 1.1, out of support) | `openbao/openbao:2.7.0` (MPL 2.0, Alpine, about 80 MB) |
| Unseal | `vault-unsealer` polls and posts Shamir keys from plaintext `vault_keys.json` | Main store: `seal "transit"` against the mini KMS. Mini KMS: built-in `seal "static"`. No custom unseal loop. |
| Storage | `file` | `raft` (snapshots, path to a cluster) |
| Listener | `tls_disable = true` | TLS from a local CA, `tls_min_version = "tls12"` |
| Audit | none | declarative `audit "file"` stanza (cannot be disabled through the API) |
| Root token | kept (the legacy transit design even put it in the seal stanza) | revoked after bootstrap; break-glass via recovery key + `generate-root` |
| Access | one token for everything | one AppRole per consumer, bound to the network subnet, minimal policy |
| Container | root processes, `IPC_LOCK` | host UID, read-only root fs, `cap_drop: ALL`, `no-new-privileges`, no host ports |

---

## 2. Bootstrap sequence

```mermaid
sequenceDiagram
    autonumber
    participant OP as init script
    participant K as openbao-kms
    participant B as openbao
    OP->>OP: openssl rand 32 → static key (mode 600)
    OP->>K: start (seal static)
    OP->>K: operator init (recovery key)
    Note over K: unsealed by the static key
    OP->>K: enable transit, key "autounseal"
    OP->>K: policy: encrypt/decrypt on that key only
    OP->>K: token create -orphan -period=24h
    OP->>OP: write seal token (mode 600, mounted only into openbao)
    OP->>K: revoke root token
    OP->>B: start (waits for the seal token file)
    B->>K: transit encrypt (barrier key)
    OP->>B: operator init (recovery key)
    Note over B: auto-unsealed through the KMS
    OP->>B: KV v2 mounts, AppRole, policies, roles
    OP->>OP: role_id/secret_id per consumer (dir 750, files 640)
    OP->>B: revoke root token
```

Rules the script follows:
- **Idempotent:** it re-runs only what is missing.
- **Tokens travel on stdin,** never in `argv` (`docker compose exec -T svc sh -c 'read -r t; BAO_TOKEN="$t" exec bao …'`), so they never appear in `ps`.
- **Never set `BAO_ADDR` in the main store's environment.** The transit seal reads `BAO_ADDR`/`BAO_TOKEN`, so a local `BAO_ADDR` would point the seal at itself. Pass it per `exec`.
- **Status:** `jq '.initialized // empty'` treats `false` as empty. Test with `has("initialized")` instead.

---

## 3. Restart and failure behaviour

```mermaid
stateDiagram-v2
    [*] --> KMSUp: start openbao-kms
    KMSUp --> KMSUnsealed: static seal (automatic)
    KMSUnsealed --> MainStarting: start openbao
    MainStarting --> MainUnsealed: transit decrypt OK
    MainStarting --> MainDown: KMS unreachable
    MainDown --> MainStarting: restart policy retries
    MainUnsealed --> MainSealed: operator seal (incident)
    MainSealed --> MainUnsealed: restart, with the KMS available
    MainUnsealed --> [*]
```

Verified in vanguard-control:
- A restart of both containers unseals both automatically.
- With the KMS stopped, the main store fails to start ("Error configuring seal transit") and retries. When the KMS returns, the main store starts and unseals on its own. This is fail closed: no secret is served without the KMS.

**Sealing is not access control.** Keep the store unsealed; control access with AppRole, policies, short token TTLs and the audit log. `seal` is the emergency brake.

---

## 4. Access model

```mermaid
flowchart TB
    subgraph POL["Policies (one per AppRole)"]
        W["writer:<br/>data/* create, update<br/>metadata/* read, delete, list<br/>(no value reads)"]
        RA["reader A:<br/>mount-a/data/* read"]
        RB["reader B:<br/>mount-b/data/* read"]
    end
    W -->|"cannot read back"| X(("values"))
    RA --> MA[("mount-a/")]
    RB --> MB[("mount-b/")]
```

Vanguard's instance of this model:

| AppRole | Policy | Can | Cannot |
|---|---|---|---|
| `api` | `vanguard-api` | create/update in `vanguard-ai/` and `vanguard-automation/`; read metadata (to verify a write) | read any value |
| `gateway` | `vanguard-gateway` | read `vanguard-ai/` (provider API keys) | read `vanguard-automation/`, write anything |
| `controller` | `vanguard-controller` | read `vanguard-automation/` (SSH, Ansible Vault passwords) | read `vanguard-ai/` |

- **Network binding:** every role has `token_bound_cidrs` and `secret_id_bound_cidrs` set to the secrets subnet. A login from any other network is refused ("unauthorized by CIDR restrictions").
- **File layout:** consumers mount only `secrets/openbao/consumers/<consumer>/` (`role_id`, `secret_id`, `ca.crt`), never the directory holding the static key or the recovery keys. Files are mode 640 with the host group, and the container gets `group_add`.
- **Audit:** secret values are HMAC-hashed in the audit log, so a key never appears there in plaintext.

---

## 5. Porting steps for this repository

1. **Images and configs:** replace `vault/Dockerfile` with the official `openbao/openbao` image. Add `config/openbao/kms.hcl` (raft, TLS, `seal "static"`, audit) and `config/openbao/bao.hcl` (raft, TLS, `seal "transit"` → `https://openbao-kms:8200`, audit). Both drop `disable_mlock`, which OpenBao 2.7 no longer accepts.
2. **Compose:** services `openbao-kms` and `openbao` with `user: HOST_UID:HOST_GID`, `read_only`, `tmpfs /tmp`, `cap_drop: ALL`, `no-new-privileges`. Networks: `kms-net` (both) and `secrets-net` (main store and consumers), with no host ports. Keep `127.0.0.1` only if a local operator port is really needed.
3. **Certificates:** a local CA, with certificates for `openbao` and `openbao-kms` (SAN: the service name, `localhost`, `127.0.0.1`).
4. **Init script:** the sequence of section 2. Store the recovery keys under `secrets/`, mode 600, never in the repository.
5. **Data migration** from the current Vault: `vault kv get`/`bao kv put` per path, or `bao operator migrate` for storage. Verify each path by version through metadata before switching clients.
6. **Retire:** delete `vault-unsealer/` and `vault-unsealer/keys/vault_keys.json` once the transit seal works. Keep `docs/legacy-transit/` as history.
7. **Checklist:**
   - restarts unseal automatically;
   - with the KMS down, the main store fails closed;
   - the policy matrix holds;
   - a login from outside the subnet is refused;
   - the root tokens are revoked;
   - the audit log shows HMAC values only.

**Production:** replace the mini KMS with a cloud KMS or HSM seal on the main store, or move the mini KMS to another host, which makes it a separate trust domain. From OpenBao 2.7 the cloud KMS seals are external plugins (kms plugin type), not part of the core binary.

---

Reference implementation (vanguard-control): `config/openbao/`, `scripts/agent_openbao_certs.sh`, `scripts/agent_openbao_init.sh`, `orchestrator/secrets.py` and `docker-compose.yml` (profile `vault`).
