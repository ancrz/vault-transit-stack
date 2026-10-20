# Main secret store. Mounts (KV v2, transit, the LDAP secrets engine), policies and AppRoles
# are declared in config/consumers.json and config/policies/ and applied by scripts/init.sh:
# each consumer reads or writes only what its policy allows.
# Auto-unseal through the mini KMS's transit engine; the seal token comes from
# BAO_TOKEN (set by the entrypoint from a file mounted only into this container).

storage "raft" {
  path    = "/openbao/file"
  node_id = "openbao-1"
}

listener "tcp" {
  address         = "0.0.0.0:8200"
  cluster_address = "0.0.0.0:8201"
  tls_cert_file   = "/openbao/tls/openbao.crt"
  tls_key_file    = "/openbao/tls/openbao.key"
  tls_min_version = "tls12"
}

# Break-glass only: a Unix socket inside the container (no network reaches it; only
# `docker compose exec` on the host, where the recovery key is kept). Since OpenBao
# 2.5.3 the unauthenticated generate-root endpoints are off by default; with every
# root token revoked, this socket is the one place they stay on, so the recovery
# key can mint a short-lived root token (scripts/init.sh revokes it).
listener "unix" {
  address                                  = "/openbao/run/break-glass.sock"
  socket_mode                              = "0600"
  disable_unauthed_generate_root_endpoints = false
}

seal "transit" {
  address         = "https://openbao-kms:8200"
  key_name        = "autounseal"
  mount_path      = "transit/"
  tls_ca_cert     = "/openbao/tls/ca.crt"
  tls_server_name = "openbao-kms"
  disable_renewal = "false"
}

# External plugins. OpenBao has no egress: scripts/plugins.sh fetches the official release, checks it and leaves it in
# this read-only directory; OpenBao registers it at start and checks the sha256 before it runs.
plugin_directory     = "/openbao/plugins"
plugin_auto_download = false

plugin "secret" "ldap" {
  command   = "openbao-plugin-secrets-ldap_linux_amd64_v1"
  version   = "v0.1.0"
  sha256sum = "47292935509894d8b4feb0fc9b6429455da87181a8fc53999eb986128ab8d73a"
}

api_addr      = "https://openbao-secrets:8200"
cluster_addr  = "https://openbao:8201"
ui            = false
log_level     = "info"

# Declarative audit: every request and response, secrets HMAC-hashed. A device in
# the config cannot be disabled through the API.
audit "file" "file" {
  description = "Audit log (secret values are HMAC-hashed)"
  options {
    file_path = "/openbao/logs/audit.log"
  }
}
