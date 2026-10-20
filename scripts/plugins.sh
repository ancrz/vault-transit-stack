#!/usr/bin/env bash
# OpenBao's external plugins, idempotent.
#
#   ./scripts/plugins.sh        # called by scripts/init.sh before OpenBao starts
#
# OpenBao has no egress, so it never downloads a plugin: this script fetches the official release
# of openbao/openbao-plugins, checks the tarball against the release's checksum file and the binary
# against the pin below, and leaves it in data/plugins/ (mounted read-only). bao.hcl declares
# the same binary and sha256 (plugin "secret" "ldap"), and OpenBao checks it again before it runs.
# The tarball's detached OpenPGP signature is checked too, against OpenBao's release key kept in the repo
# (config/openbao/openbao-gpg-pub-20240618.asc, from openbao.org/docs/install; its primary fingerprint pinned
# below). The plugin releases carry .sig files, no sigstore bundle, so this is GPG, not cosign. Without gpg on the host the pin alone decides, with a warning.
# A new version: change PLUGIN_VERSION, BINARY_SHA256 here and the plugin stanza in bao.hcl.
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIR="${PROJECT_ROOT}/data/plugins"

# The LDAP secrets engine: OpenBao owns and rotates a directory's service accounts (mount type
# "ldap" in config/consumers.json).
PLUGIN_TAG="secrets-ldap-v0.1.0"
ASSET="openbao-plugin-secrets-ldap_linux_amd64_v1"
BINARY_SHA256="47292935509894d8b4feb0fc9b6429455da87181a8fc53999eb986128ab8d73a"
BASE="https://github.com/openbao/openbao-plugins/releases/download/${PLUGIN_TAG}"
RELEASE_KEY="${PROJECT_ROOT}/config/openbao/openbao-gpg-pub-20240618.asc"
RELEASE_KEY_FPR="66D15FDD87287219C8E15478D200CD702853E6D0"

log() { echo "[openbao-plugins] $*"; }

mkdir -p "${DIR}"
chmod 755 "${DIR}"
if [ -f "${DIR}/${ASSET}" ] && echo "${BINARY_SHA256}  ${DIR}/${ASSET}" | sha256sum -c --status -; then
  log "${ASSET} present and verified"
  exit 0
fi

work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT
log "fetching ${PLUGIN_TAG} (${ASSET})"
curl -fsSL --retry 3 -o "${work}/${ASSET}.tar.gz" "${BASE}/${ASSET}.tar.gz"
curl -fsSL --retry 3 -o "${work}/checksums.txt" "${BASE}/checksums-secrets-ldap.txt"
( cd "${work}" && grep " ${ASSET}.tar.gz\$" checksums.txt | sha256sum -c --status - ) \
  || { log "the tarball does not match the release's checksum file"; exit 1; }
if command -v gpg >/dev/null 2>&1; then
  curl -fsSL --retry 3 -o "${work}/${ASSET}.tar.gz.sig" "${BASE}/${ASSET}.tar.gz.sig"
  mkdir -m 700 "${work}/gnupg"
  GNUPGHOME="${work}/gnupg" gpg --batch -q --import "${RELEASE_KEY}" 2>/dev/null \
    || { log "cannot read OpenBao's release key ${RELEASE_KEY}"; exit 1; }
  # VALIDSIG <signing key fpr> … <primary key fpr>: a good signature by a key whose primary is OpenBao's
  GNUPGHOME="${work}/gnupg" gpg --batch --status-fd 1 --verify "${work}/${ASSET}.tar.gz.sig" "${work}/${ASSET}.tar.gz" \
    2>/dev/null | grep -Eq "^\[GNUPG:\] VALIDSIG .* ${RELEASE_KEY_FPR}\$" \
    || { log "the tarball's signature is not OpenBao's release key (${RELEASE_KEY_FPR})"; exit 1; }
  log "signature: OpenBao's release key (${RELEASE_KEY_FPR:0:16}…)"
else
  log "WARN gpg not found: the release signature is not checked (the pinned sha256 still is)"
fi
mkdir "${work}/x"
tar -xzf "${work}/${ASSET}.tar.gz" -C "${work}/x" "${ASSET}"
echo "${BINARY_SHA256}  ${work}/x/${ASSET}" | sha256sum -c --status - \
  || { log "the binary does not match the pinned sha256 (BINARY_SHA256)"; exit 1; }
install -m 0755 "${work}/x/${ASSET}" "${DIR}/${ASSET}"
log "${ASSET} installed in data/plugins (sha256 ${BINARY_SHA256:0:12}…)"
