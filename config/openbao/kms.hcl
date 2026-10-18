# Mini KMS: a transit-only OpenBao that holds the main store's
# unseal key, so the main store auto-unseals without people holding shares.
# Its own unseal is the built-in static seal: a 32-byte key mounted only here.
# Production swaps this container for a cloud KMS/HSM seal on the main store,
# or runs it on another host (a separate trust domain).

storage "raft" {
  path    = "/openbao/file"
  node_id = "openbao-kms-1"
}

listener "tcp" {
  address         = "0.0.0.0:8200"
  cluster_address = "0.0.0.0:8201"
  tls_cert_file   = "/openbao/tls/openbao-kms.crt"
  tls_key_file    = "/openbao/tls/openbao-kms.key"
  tls_min_version = "tls12"
}

# Break-glass only, as on the main store (config/openbao/bao.hcl): a Unix socket in a host
# directory (mode 700) where the recovery key can mint a short-lived root token, used by
# scripts/init.sh to configure the seal AppRole and rotate its secret_id.
listener "unix" {
  address                                  = "/openbao/run/break-glass.sock"
  socket_mode                              = "0600"
  disable_unauthed_generate_root_endpoints = false
}

seal "static" {
  current_key_id = "kms-unseal-1"
  current_key    = "file:///openbao/unseal/kms-unseal-1.key"
}

api_addr      = "https://openbao-kms:8200"
cluster_addr  = "https://openbao-kms:8201"
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
