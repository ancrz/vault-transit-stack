# Pending refactor: HashiCorp Vault → OpenBao

Status: **pending** (noted 2026-09-30). Nothing in this stack has changed yet.

## What

Replace the HashiCorp Vault image in this stack with **OpenBao**, keeping the same layout (one secrets store, automatic unseal), and fix the unseal design at the same time.

| Today | After the refactor |
|---|---|
| `hashicorp/vault` 1.15.4 (`VAULT_TAG`) | `openbao/openbao`, a current release, pinned |
| Shamir seal, unsealed by the `vault-unsealer` sidecar reading plaintext `vault_keys.json` | Main store: `seal "transit"` against a small **transit-only OpenBao** ("mini KMS"). The mini KMS itself uses the built-in `seal "static"` (a key file mounted only into it). |
| Legacy two-vault design (`docs/legacy-transit/`) puts the **root token** in the `seal "transit"` stanza | A token bound to the existing `autounseal` policy (encrypt/decrypt on one key only); the root token is revoked after bootstrap |
| `storage "file"`, `tls_disable = true` | `storage "raft"` (snapshots, a path to a cluster), TLS on the listener |
| No audit device | File audit device enabled |

The CLI and HTTP API are the same (`bao` instead of `vault`; `/v1/...` paths unchanged), so scripts and the unsealer logic port with renames.

## Why

1. **License.** Since August 2023, Vault releases from 1.15 on are under the **Business Source License 1.1** (IBM has been the licensor since it acquired HashiCorp in February 2025). The 1.15.4 pinned here is already BSL.
   - Production use is allowed, except "offering the Licensed Work to third parties on a hosted or embedded basis in order to compete with" IBM's paid versions. Whether a product competes is IBM's reading, not ours.
   - Each version turns into MPL 2.0 only four years after its release.
   - OpenBao is the Linux Foundation fork of Vault 1.14, under **MPL 2.0**, with the same API. It removes that uncertainty for anything we ship to others.
2. **Support.** Vault 1.15 is out of support. OpenBao is actively released: v2.6 (July 2026) added pluggable auto-unseal, and v2.7 came out on 2026-09-23. Note that from 2.7 the cloud KMS seals ship as external plugins, not in the core binary.
3. **Unseal design.** A sidecar with the unseal keys in a plaintext file on the same host gives availability, not protection at rest.
   - The industry keeps the unseal key **outside** the store: a cloud KMS, an HSM, or Transit on another instance.
   - A transit-only mini KMS gives the same code path as production: moving to a real KMS, or moving the mini KMS to another host, is a configuration change.
   - OpenBao's `static` seal replaces the custom unsealer loop for the mini KMS.
4. **Sealing is not access control.** The store stays unsealed; access is AppRole plus policies plus short-lived tokens plus audit. `seal` is the emergency brake during an incident.

## Reference

This design is being implemented first in **vanguard-control** (remediation R1: its own OpenBao with a mini KMS; mounts `vanguard-ai/` and `vanguard-automation/`; per-consumer AppRoles). Port it back here from there.

Sources:
- [Vault BSL 1.1 license text](https://raw.githubusercontent.com/hashicorp/vault/main/LICENSE)
- [HashiCorp license FAQ](https://www.hashicorp.com/en/license-faq)
- [OpenBao v2.6 announcement](https://openssf.org/blog/2026/08/06/announcing-openbao-v2-6/)
- [OpenBao 2.7 release notes](https://openbao.org/community/release-notes/2-7-0/)
- [OpenBao static seal](https://openbao.org/docs/configuration/seal/static/)
