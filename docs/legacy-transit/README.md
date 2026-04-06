# Legacy Transit Auto-Unseal Archive

This directory contains the archived dual-vault transit auto-unseal configuration
that previously operated this stack. It is preserved for reference and is not
used in the current setup.

## What This Archive Contains

| Path | Description |
|------|-------------|
| `vault-a/` | Transit Vault (unsealer) — provided transit auto-unseal for vault-b |
| `vault-b/` | Application Vault (unsealed by transit) — held application secrets |
| `docker-compose.yml` | Dual-service Compose config for both vault-a and vault-b |
| `legacy-setup.md` | Original setup instructions for the transit stack |
| `vault-architecture.md` | Architecture documentation for the dual-vault design |
| `first-time-setup.md` | First-time initialization guide for the transit stack |

## When Transit Auto-Unseal IS the Right Choice

Transit auto-unseal is a powerful pattern that remains the correct choice in
several scenarios. This stack superseded it for a different reason (single
bare-metal server), not because the pattern is flawed.

**Multi-datacenter deployments**
When application vaults span multiple datacenters or cloud regions, a transit
vault running in a separate failure domain can unseal them automatically on
restart without human intervention — without exposing Shamir key shares across
networks.

**Multi-tenant environments**
Organizations operating separate Vault instances per team, department, or
customer can centralize unsealing via a single transit vault with per-tenant
transit keys. This allows key rotation and revocation at scale without
distributing Shamir shares to each tenant's ops team.

**Ephemeral application vaults**
In Kubernetes or cloud-native deployments where vault pods restart frequently
(node drain, rolling upgrades, pod eviction), transit auto-unseal eliminates
the operational burden of manual or cron-based re-unsealing after each restart.

**Compliance segregation**
Regulatory requirements sometimes mandate separation between the entity that
holds encryption keys and the entity that holds secrets. A transit vault owned
by a security team can unseal an application vault owned by an engineering team
without the security team having access to application secrets.

**Automated CI/CD pipelines**
Ephemeral vault instances spun up for test pipelines benefit from transit
auto-unseal when pipeline runners cannot store Shamir shares securely but can
authenticate to a persistent transit vault via AppRole or Kubernetes auth.

## Why It Was Superseded Here

This project runs on a single bare-metal server with no secondary infrastructure.
Running two Vault instances on the same host to achieve auto-unseal provides no
meaningful availability or security benefit — if the host reboots, both vaults
restart together and vault-a must be unsealed first anyway, negating the
automation advantage.

The replacement architecture (single Vault + Ansible-managed Shamir unseal)
achieves the same operational outcome — automated unsealing after reboot — with
half the resource footprint and simpler operational runbooks.

If this stack is later deployed across multiple hosts, transit auto-unseal
should be reconsidered. The archived configuration in this directory provides
a ready starting point.
