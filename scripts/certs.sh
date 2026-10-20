#!/usr/bin/env bash
# TLS for the OpenBao containers, issued by a local CA (idempotent).
#
#   ./scripts/certs.sh            # create what is missing
#   ./scripts/certs.sh --force    # reissue the server certificates (keeps the CA)
#   ./scripts/certs.sh --check    # days left on each certificate
#
# The CA key and the server keys are generated at random the first time; nothing is seeded
# from .env. Output (gitignored, mode 600 keys): secrets/ca/{ca.crt,ca.key} and
# secrets/tls/{ca.crt, openbao.crt/.key, openbao-kms.crt/.key}. Consumers trust ca.crt
# (init.sh copies it into each consumer's directory).
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CA_DIR="${PROJECT_ROOT}/secrets/ca"
DIR="${PROJECT_ROOT}/secrets/tls"
DAYS="${BAO_CERT_DAYS:-397}"
CA_DAYS="${BAO_CA_DAYS:-3650}"
MODE="${1:-}"

command -v openssl >/dev/null || { echo "[certs] openssl is required" >&2; exit 1; }

days_left() {  # days until the certificate in $1 expires (negative when expired)
  local end
  end=$(openssl x509 -enddate -noout -in "$1" 2>/dev/null | cut -d= -f2) || return 1
  echo $(( ($(date -d "${end}" +%s) - $(date +%s)) / 86400 ))
}

if [ "${MODE}" = "--check" ]; then
  for c in "${CA_DIR}/ca.crt" "${DIR}/openbao.crt" "${DIR}/openbao-kms.crt"; do
    [ -f "$c" ] && echo "$(basename "$c")=$(days_left "$c")d" || echo "$(basename "$c")=missing"
  done
  exit 0
fi

mkdir -p "${CA_DIR}" "${DIR}"
chmod 700 "${PROJECT_ROOT}/secrets" "${CA_DIR}" "${DIR}"
umask 077

if [ ! -f "${CA_DIR}/ca.key" ]; then
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days "${CA_DAYS}" \
    -keyout "${CA_DIR}/ca.key" -out "${CA_DIR}/ca.crt" -subj "/CN=vault-transit-stack local CA" \
    -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
  chmod 600 "${CA_DIR}/ca.key"; chmod 644 "${CA_DIR}/ca.crt"
  echo "[certs] created the local CA (${CA_DIR}/ca.crt)"
fi

# openbao-secrets: the secrets-network alias consumers use (docker-compose.yml); a certificate
# issued without it is issued again.
if [ -f "${DIR}/openbao.crt" ] && [ -f "${DIR}/openbao-kms.crt" ] && [ "${MODE}" != "--force" ] && \
   openssl x509 -noout -ext subjectAltName -in "${DIR}/openbao.crt" 2>/dev/null | grep -q "DNS:openbao-secrets"; then
  echo "[certs] certificates present (${DIR}); --force to reissue."
  exit 0
fi
cp "${CA_DIR}/ca.crt" "${DIR}/ca.crt"
san_for() { [ "$1" = "openbao" ] && echo "DNS:openbao,DNS:openbao-secrets" || echo "DNS:$1"; }
for name in openbao openbao-kms; do
  openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout "${DIR}/${name}.key" \
    -out "${DIR}/${name}.csr" -subj "/CN=${name}" 2>/dev/null
  openssl x509 -req -in "${DIR}/${name}.csr" -CA "${CA_DIR}/ca.crt" -CAkey "${CA_DIR}/ca.key" -CAcreateserial \
    -days "${DAYS}" -out "${DIR}/${name}.crt" \
    -extfile <(printf "subjectAltName=%s,DNS:localhost,IP:127.0.0.1\nextendedKeyUsage=serverAuth,clientAuth\nkeyUsage=critical,digitalSignature\nbasicConstraints=CA:FALSE\n" "$(san_for "${name}")") 2>/dev/null
  rm -f "${DIR}/${name}.csr"
done
chmod 644 "${DIR}"/*.crt
chmod 600 "${DIR}"/*.key
echo "[certs] issued ${DIR}/openbao.crt and openbao-kms.crt (CA: ${DIR}/ca.crt)"
