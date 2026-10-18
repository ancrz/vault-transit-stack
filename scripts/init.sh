#!/usr/bin/env bash
# Bootstrap and reconfigure the OpenBao secret store (the unseal pipeline).
# Extracted from vanguard-control (scripts/agent_openbao_init.sh and agent_openbao_plugins.sh).
#
#   ./scripts/init.sh          # idempotent: does only what is missing; safe to re-run
#
# 1. Mini KMS (openbao-kms): static-seal key → init (recovery key) → transit engine with
#    key "autounseal" → policy limited to encrypt/decrypt on it → an AppRole "main-seal"
#    (the main store logs in at every start; its secret_id expires after a year and is
#    rotated 30 days ahead) → root token revoked. Later runs configure it through the KMS's
#    own break-glass socket.
# 2. Main store (openbao): init (auto-unsealed by the KMS; recovery key) → root token.
# 0. External plugins (scripts/plugins.sh): the LDAP secrets engine, fetched on the host,
#    checked against its release checksum, OpenBao's GPG release key and a pinned sha256.
# 3. Configuration (every run, idempotent), from config/consumers.json and config/policies/:
#    mounts (kv-v2, transit + keys, ldap), policies, one AppRole per consumer bound to the secrets
#    subnet, and each consumer's role_id, secret_id and CA under secrets/consumers/<name>/.
#    On an already initialised store the root token comes from break-glass (generate-root
#    with the recovery key, read from init.json on stdin). Every root token is revoked at
#    the end.
#
# Written under secrets/ (mode 600, gitignored): the KMS unseal key (the trust anchor), each
# init's recovery key (break-glass: generate-root), the seal AppRole's role_id and
# secret_id, and the consumers' AppRole credentials. Tokens travel on stdin, never in argv,
# so they do not show in the process list.
#
# Consumers mount only their own directory (secrets/consumers/<name>, mode 750, files 640,
# the host group; the consumer's compose adds that group to its container), never secrets/
# itself, which holds the unseal key and the recovery keys.
#
# Host requirements: docker compose, jq, openssl, python3, curl (gpg recommended).
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${PROJECT_ROOT}"
# .env fills only what the environment does not set (a variable on the command line wins).
load_env() {
  [ -f "$1" ] || return 0
  local line key
  while IFS= read -r line || [ -n "${line}" ]; do
    [[ "${line}" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
    key=${BASH_REMATCH[1]}
    [ -n "${!key+x}" ] || export "${key}=${BASH_REMATCH[2]}"
  done < "$1"
}
load_env .env
S="${PROJECT_ROOT}/secrets"
D="${PROJECT_ROOT}/data"
CONSUMERS_FILE="${BAO_CONSUMERS_FILE:-${PROJECT_ROOT}/config/consumers.json}"
POLICY_DIR="${BAO_POLICY_DIR:-${PROJECT_ROOT}/config/policies}"
SUBNET="${BAO_SECRETS_SUBNET:-172.30.30.0/24}"
KMS_SUBNET="${BAO_KMS_SUBNET:-172.30.48.0/24}"
export HOST_UID="${HOST_UID:-$(id -u)}" HOST_GID="${HOST_GID:-$(id -g)}"
for bin in docker jq openssl python3; do
  command -v "${bin}" >/dev/null || { echo "[openbao] ${bin} is required" >&2; exit 1; }
done
jq -e '.consumers | type == "object"' "${CONSUMERS_FILE}" >/dev/null \
  || { echo "[openbao] ${CONSUMERS_FILE}: no consumers object" >&2; exit 1; }
umask 077

log() { echo "[openbao] $*"; }

# External plugins first: bao.hcl declares them, so they must be on disk before the main store starts.
"${PROJECT_ROOT}/scripts/plugins.sh"

# bao <service> <token-or-empty> args… ; extra stdin after the token line is passed through.
bao() {
  local svc=$1 token=$2; shift 2
  { printf '%s\n' "${token}"; cat; } | docker compose exec -T "${svc}" sh -c \
    'IFS= read -r t; [ -n "$t" ] && export BAO_TOKEN="$t"; export BAO_ADDR=https://127.0.0.1:8200 BAO_CACERT=/openbao/tls/ca.crt; exec bao "$@"' sh "$@"
}
status() { bao "$1" "" status -format=json </dev/null 2>/dev/null || true; }
# bao_sock [--kms] <method> <path> [--data-stdin]: a raw HTTP call to a store's break-glass
# Unix socket (only the legacy, unauthenticated generate-root endpoints): the main store's by
# default, the KMS's with --kms.
bao_sock() {
  local run="${D}/run"
  [ "$1" = "--kms" ] && { run="${D}/kms-run"; shift; }
  local method=$1 path=$2 data=""
  [ "${3:-}" = "--data-stdin" ] && data=$(cat)
  docker run --rm -i --user "${HOST_UID}:${HOST_GID}" -v "${run}:/run/bao" --network none \
    "${CURL_IMAGE:-curlimages/curl:8.11.1}" \
    -sS --unix-socket /run/bao/break-glass.sock -X "${method}" "http://localhost/v1/${path}" \
    ${data:+-H "Content-Type: application/json" --data-binary @-} <<<"${data}"
}
# break_glass [--kms] <init.json>: a short-lived root token from the recovery key (stdin to
# the socket), printed on stdout. The caller revokes it.
break_glass() {
  local sock=() init
  [ "$1" = "--kms" ] && { sock=(--kms); shift; }
  init=$1
  bao_sock "${sock[@]}" DELETE sys/generate-root/attempt >/dev/null 2>&1 || true
  local attempt otp nonce encoded
  attempt=$(bao_sock "${sock[@]}" PUT sys/generate-root/attempt)
  otp=$(echo "${attempt}" | jq -r .otp); nonce=$(echo "${attempt}" | jq -r .nonce)
  encoded=$(jq -c --arg n "${nonce}" '{key: .recovery_keys_b64[0], nonce: $n}' "${init}" \
    | bao_sock "${sock[@]}" PUT sys/generate-root/update --data-stdin | jq -r .encoded_token)
  [ -n "${encoded}" ] && [ "${encoded}" != "null" ] || { echo "[openbao] break-glass failed" >&2; return 1; }
  # Decode locally (the CLI's -decode asks the authenticated endpoint first): token = base64(encoded) XOR otp.
  printf '%s\n%s\n' "${encoded}" "${otp}" | python3 -c \
    'import base64,sys; e,o=sys.stdin.read().split(); print(bytes(a^b for a,b in zip(base64.b64decode(e+"="*(-len(e)%4)),o.encode())).decode())'
}
# The main store's seal credential is not a static token: an AppRole "main-seal" on the KMS.
# The main store logs in at every start (OpenBao Agent's auto-auth pattern) and the transit
# seal renews that token while it runs, so a stop of any length never leaves it without one.
# Its secret_id expires (BAO_SEAL_SECRET_TTL, default 8760h) and is rotated when less than
# BAO_SEAL_ROTATE_BEFORE_H (default 720h) is left. Both are bound to the KMS subnet. The
# consumers' AppRoles on the main store follow the same TTL and rotation window.
SEAL_TTL="${BAO_SEAL_SECRET_TTL:-8760h}"
SEAL_ROTATE_BEFORE_S=$(( ${BAO_SEAL_ROTATE_BEFORE_H:-720} * 3600 ))
# rotate_secret_id <service> <root> <role> <dir>: keep <dir>/secret_id valid. A new one is
# written (atomically) when it is missing, does not expire, or has less than the rotation
# window left; then the old one is destroyed. Its holder re-reads the file at its next login
# and keeps the token it has (destroying a secret_id does not revoke tokens).
rotate_secret_id() {
  local svc=$1 root=$2 role=$3 dir=$4 left=-1 old_accessor=""
  if [ -s "${dir}/secret_id" ]; then
    local info
    info=$( { printf '{"secret_id":"%s"}' "$(cat "${dir}/secret_id")"; } \
      | bao "${svc}" "${root}" write -format=json "auth/approle/role/${role}/secret-id/lookup" - 2>/dev/null || true)
    old_accessor=$(echo "${info}" | jq -r '.data.secret_id_accessor // empty' 2>/dev/null || true)
    left=$(echo "${info}" | jq -r '.data.expiration_time // empty' 2>/dev/null | python3 -c '
import sys, datetime as d
t = sys.stdin.read().strip()
if not t: print(-1)
else:
    e = d.datetime.fromisoformat(t.replace("Z", "+00:00"))
    print(-1 if e.year < 1970 else int((e - d.datetime.now(d.timezone.utc)).total_seconds()))')
  fi
  if [ "${left}" -lt "${SEAL_ROTATE_BEFORE_S}" ]; then
    bao "${svc}" "${root}" write -f -field=secret_id "auth/approle/role/${role}/secret-id" </dev/null > "${dir}/secret_id.new"
    chmod --reference="${dir}/secret_id" "${dir}/secret_id.new" 2>/dev/null || true
    mv "${dir}/secret_id.new" "${dir}/secret_id"
    [ -n "${old_accessor}" ] && printf '{"secret_id_accessor":"%s"}' "${old_accessor}" \
      | bao "${svc}" "${root}" write "auth/approle/role/${role}/secret-id-accessor/destroy" - >/dev/null
    log "${role}: new secret_id (valid ${SEAL_TTL}; the old one $( [ -n "${old_accessor}" ] && echo destroyed || echo was missing))"
  else
    log "${role}: secret_id valid for $(( left / 86400 )) more days (rotated at $(( SEAL_ROTATE_BEFORE_S / 86400 )))"
  fi
}
configure_seal_approle() {   # configure_seal_approle <kms root>
  local root=$1 sd="${S}/main/seal"
  bao openbao-kms "${root}" auth list -format=json </dev/null | jq -e 'has("approle/")' >/dev/null \
    || bao openbao-kms "${root}" auth enable approle </dev/null >/dev/null
  # A secret_id's TTL is capped by its mount's max lease TTL (768h by default).
  bao openbao-kms "${root}" auth tune -max-lease-ttl="${SEAL_TTL}" approle/ </dev/null >/dev/null
  bao openbao-kms "${root}" write auth/approle/role/main-seal token_policies=autounseal token_period=24h \
    token_bound_cidrs="${KMS_SUBNET}" secret_id_bound_cidrs="${KMS_SUBNET}" secret_id_ttl="${SEAL_TTL}" \
    secret_id_num_uses=0 </dev/null >/dev/null
  bao openbao-kms "${root}" read -field=role_id auth/approle/role/main-seal/role-id </dev/null > "${sd}/role_id"
  rotate_secret_id openbao-kms "${root}" main-seal "${sd}"
  chmod 600 "${sd}/role_id" "${sd}/secret_id"
}
# No other root token may outlive this run (e.g. one minted by an interrupted break-glass).
revoke_stray_roots() {   # revoke_stray_roots <service> <root>
  local svc=$1 root=$2 self acc
  self=$(bao "${svc}" "${root}" token lookup -format=json </dev/null | jq -r .data.accessor)
  for acc in $(bao "${svc}" "${root}" list -format=json auth/token/accessors </dev/null | jq -r '.[]'); do
    [ "${acc}" = "${self}" ] && continue
    if bao "${svc}" "${root}" token lookup -accessor -format=json "${acc}" </dev/null 2>/dev/null | jq -e '.data.policies | index("root")' >/dev/null; then
      bao "${svc}" "${root}" token revoke -accessor "${acc}" </dev/null >/dev/null && log "${svc}: revoked a stray root token (accessor ${acc:0:8}…)"
    fi
  done
}
wait_up() {
  for _ in $(seq 1 40); do
    status "$1" | jq -e 'has("initialized")' >/dev/null 2>&1 && return 0
    sleep 2
  done
  echo "[openbao] $1 did not answer" >&2; exit 1
}
wait_unsealed() {
  for _ in $(seq 1 30); do [ "$(status openbao | jq -r .sealed)" = "false" ] && return 0; sleep 1; done
  echo "[openbao] the main store is still sealed (is the KMS up? docker compose logs openbao)" >&2; exit 1
}

mkdir -p "${S}/kms/unseal" "${S}/main/seal" "${S}/consumers" "${D}"/{kms,kms-logs,kms-run,main,main-logs,run,plugins}
chmod 700 "${D}/run" "${D}/kms-run"
chmod 700 "${S}/kms" "${S}/kms/unseal" "${S}/main" "${S}/main/seal"
chmod 750 "${S}" "${S}/consumers"
./scripts/certs.sh

# ── 1. Mini KMS ───────────────────────────────────────────────────────────────
KEY="${S}/kms/unseal/kms-unseal-1.key"
if [ ! -s "${KEY}" ]; then
  openssl rand -out "${KEY}" 32
  log "generated the KMS static-seal key (${KEY})"
fi
chmod 600 "${KEY}"
docker compose up -d openbao-kms >/dev/null
wait_up openbao-kms

if [ "$(status openbao-kms | jq -r .initialized)" != "true" ]; then
  bao openbao-kms "" operator init -recovery-shares=1 -recovery-threshold=1 -format=json </dev/null > "${S}/kms/init.json"
  ROOT=$(jq -r .root_token "${S}/kms/init.json")
  sleep 2
  bao openbao-kms "${ROOT}" secrets enable -path=transit transit </dev/null >/dev/null
  bao openbao-kms "${ROOT}" write -f transit/keys/autounseal </dev/null >/dev/null
  bao openbao-kms "${ROOT}" policy write autounseal - >/dev/null < config/openbao/kms-autounseal.hcl
  configure_seal_approle "${ROOT}"
  bao openbao-kms "${ROOT}" token revoke -self </dev/null >/dev/null
  jq 'del(.root_token)' "${S}/kms/init.json" > "${S}/kms/init.tmp" && mv "${S}/kms/init.tmp" "${S}/kms/init.json"
  unset ROOT
  log "KMS initialised: transit key autounseal, seal AppRole main-seal, root token revoked"
else
  # Configuration on every run (idempotent), as root from the KMS break-glass, revoked below.
  log "KMS already initialised; checking the seal AppRole"
  KROOT=$(break_glass --kms "${S}/kms/init.json")
  configure_seal_approle "${KROOT}"
  revoke_stray_roots openbao-kms "${KROOT}"
  bao openbao-kms "${KROOT}" token revoke -self </dev/null >/dev/null
  unset KROOT
fi
chmod 600 "${S}/kms/init.json"

# ── 2. Main store ─────────────────────────────────────────────────────────────
docker compose up -d openbao >/dev/null
wait_up openbao
if [ "$(status openbao | jq -r .initialized)" = "true" ]; then
  wait_unsealed
  log "main store already initialised and unsealed; checking its configuration"
  # Break-glass: a short-lived root token from the recovery key (stdin), revoked below,
  # through the container-local Unix socket (the only listener with generate-root on).
  ROOT=$(break_glass "${S}/main/init.json") || exit 1
else
  bao openbao "" operator init -recovery-shares=1 -recovery-threshold=1 -format=json </dev/null > "${S}/main/init.json"
  chmod 600 "${S}/main/init.json"
  ROOT=$(jq -r .root_token "${S}/main/init.json")
  wait_unsealed
  log "main store initialised and auto-unsealed through the KMS"
fi

# ── 3. Configuration (idempotent) ─────────────────────────────────────────────
# A store started before the plugin stanza existed has not registered it: reload bao.hcl.
# `up -d` recreates the container when its definition changed (the plugins volume); `restart`
# reloads bao.hcl when only the file did. The break-glass root token survives both (it is stored).
ldap_plugin() { bao openbao "${ROOT}" plugin info -version=v0.1.0 secret ldap </dev/null >/dev/null 2>&1; }
if ! ldap_plugin; then
  log "registering the LDAP secrets plugin (reloading the main store with bao.hcl)"
  for step in "up -d" "restart"; do
    docker compose ${step} openbao >/dev/null 2>&1
    wait_up openbao
    wait_unsealed
    ldap_plugin && break
  done
  ldap_plugin || { log "the LDAP secrets plugin did not register (docker compose logs openbao)"; exit 1; }
fi
MOUNTS=$(bao openbao "${ROOT}" secrets list -format=json </dev/null)
while IFS= read -r m; do
  path=$(jq -r .path <<<"${m}"); type=$(jq -r .type <<<"${m}"); desc=$(jq -r '.description // ""' <<<"${m}")
  if ! echo "${MOUNTS}" | jq -e --arg p "${path}/" 'has($p)' >/dev/null; then
    case "${type}" in
      kv-v2)   bao openbao "${ROOT}" secrets enable -path="${path}" -description="${desc}" -version=2 kv </dev/null >/dev/null ;;
      transit) bao openbao "${ROOT}" secrets enable -path="${path}" -description="${desc}" transit </dev/null >/dev/null ;;
      # One LDAP engine holds one directory's config: one mount per directory.
      ldap)    bao openbao "${ROOT}" secrets enable -path="${path}" -description="${desc}" -plugin-version=v0.1.0 ldap </dev/null >/dev/null ;;
      *) echo "[openbao] mount ${path}: unknown type ${type} (kv-v2 | transit | ldap)" >&2; exit 1 ;;
    esac
    log "mount ${path}/ (${type}) enabled"
  fi
  if [ "${type}" = "transit" ]; then
    while IFS= read -r k; do
      kname=$(jq -r .name <<<"${k}"); ktype=$(jq -r '.type // "aes256-gcm96"' <<<"${k}")
      bao openbao "${ROOT}" read "${path}/keys/${kname}" </dev/null >/dev/null 2>&1 \
        || { bao openbao "${ROOT}" write -f "${path}/keys/${kname}" type="${ktype}" </dev/null >/dev/null; log "transit key ${path}/${kname} (${ktype}) created"; }
    done < <(jq -c '.keys // [] | .[]' <<<"${m}")
  fi
done < <(jq -c '.mounts // [] | .[]' "${CONSUMERS_FILE}")

bao openbao "${ROOT}" auth list -format=json </dev/null | jq -e 'has("approle/")' >/dev/null \
  || bao openbao "${ROOT}" auth enable approle </dev/null >/dev/null
bao openbao "${ROOT}" auth tune -max-lease-ttl="${SEAL_TTL}" approle/ </dev/null >/dev/null   # caps secret_id TTLs

for policy in $(jq -r '[.consumers[].policies[]] | unique | .[]' "${CONSUMERS_FILE}"); do
  [ -f "${POLICY_DIR}/${policy}.hcl" ] || { echo "[openbao] policy ${policy}: ${POLICY_DIR}/${policy}.hcl is missing" >&2; exit 1; }
  bao openbao "${ROOT}" policy write "${policy}" - >/dev/null < "${POLICY_DIR}/${policy}.hcl"
done

for consumer in $(jq -r '.consumers | keys[]' "${CONSUMERS_FILE}"); do
  [[ "${consumer}" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || { echo "[openbao] consumer name ${consumer}: use [a-z0-9_-]" >&2; exit 1; }
  c=$(jq -c --arg n "${consumer}" '.consumers[$n]' "${CONSUMERS_FILE}")
  bao openbao "${ROOT}" write "auth/approle/role/${consumer}" \
    token_policies="$(jq -r '.policies | join(",")' <<<"${c}")" \
    token_ttl="$(jq -r '.token_ttl // "1h"' <<<"${c}")" token_max_ttl="$(jq -r '.token_max_ttl // "4h"' <<<"${c}")" \
    secret_id_ttl="${SEAL_TTL}" token_bound_cidrs="${SUBNET}" secret_id_bound_cidrs="${SUBNET}" </dev/null >/dev/null
  C="${S}/consumers/${consumer}"
  mkdir -p "${C}"
  bao openbao "${ROOT}" read -field=role_id "auth/approle/role/${consumer}/role-id" </dev/null > "${C}/role_id"
  # Consumers re-read secret_id at every login, so rotation needs no restart.
  rotate_secret_id openbao "${ROOT}" "${consumer}" "${C}"
  cp "${S}/tls/ca.crt" "${C}/ca.crt"
  chmod 750 "${C}"
  chmod 640 "${C}/role_id" "${C}/secret_id" "${C}/ca.crt"
done

revoke_stray_roots openbao "${ROOT}"
bao openbao "${ROOT}" token revoke -self </dev/null >/dev/null
unset ROOT
if jq -e 'has("root_token")' "${S}/main/init.json" >/dev/null; then
  jq 'del(.root_token)' "${S}/main/init.json" > "${S}/main/init.tmp" && mv "${S}/main/init.tmp" "${S}/main/init.json"
fi
chmod 600 "${S}/main/init.json"
log "main store configured: mounts [$(jq -r '[.mounts[].path] | join(", ")' "${CONSUMERS_FILE}")], AppRoles [$(jq -r '.consumers | keys | join(", ")' "${CONSUMERS_FILE}")]; root token revoked"
log "consumers: mount secrets/consumers/<name> read-only and join the ${BAO_SECRETS_NETWORK_NAME:-bao-secrets-net} network"
