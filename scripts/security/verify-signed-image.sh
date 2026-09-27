#!/usr/bin/env bash
set -Eeuo pipefail

REPOSITORY=""
DIGEST=""
REVISION=""
SOURCE_REPOSITORY="${GITHUB_REPOSITORY:-}"
WORKFLOW_PATH=".github/workflows/build.yml"
EVIDENCE_DIR="signing-evidence"

log() { printf '[INFO] %s\n' "$*"; }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Falta el comando requerido: $1"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repository) REPOSITORY="$2"; shift 2 ;;
    --digest) DIGEST="$2"; shift 2 ;;
    --revision) REVISION="$2"; shift 2 ;;
    --source-repository) SOURCE_REPOSITORY="$2"; shift 2 ;;
    --workflow-path) WORKFLOW_PATH="$2"; shift 2 ;;
    --evidence-dir) EVIDENCE_DIR="$2"; shift 2 ;;
    -h|--help)
      echo "Uso: verify-signed-image.sh --repository REPO --digest sha256:... --revision SHA40 --source-repository OWNER/REPO"
      exit 0
      ;;
    *) die "Opción desconocida: $1" ;;
  esac
done

require_cmd cosign
require_cmd gh
require_cmd jq

[[ -n "$REPOSITORY" ]] || die "--repository es obligatorio"
[[ "$DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || die "--digest debe ser SHA-256 OCI"
[[ "$REVISION" =~ ^[0-9a-f]{40}$ ]] || die "--revision debe ser SHA Git de 40 hex"
[[ "$SOURCE_REPOSITORY" =~ ^[^/]+/[^/]+$ ]] || die "--source-repository debe ser OWNER/REPO"
[[ -n "${GH_TOKEN:-}" ]] || die "GH_TOKEN no definido"

mkdir -p "$EVIDENCE_DIR"

image_ref="${REPOSITORY}@${DIGEST}"
oci_ref="oci://${image_ref}"
cert_identity="https://github.com/${SOURCE_REPOSITORY}/${WORKFLOW_PATH}@refs/heads/main"
signer_workflow="${SOURCE_REPOSITORY}/${WORKFLOW_PATH}"

log "Verificando firma keyless Cosign"
cosign verify \
  --certificate-identity "$cert_identity" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
  "$image_ref" \
  | tee "${EVIDENCE_DIR}/cosign-verify.json" >/dev/null

jq -e 'type == "array" and length > 0' "${EVIDENCE_DIR}/cosign-verify.json" >/dev/null

log "Verificando provenance SLSA desde OCI"
gh attestation verify "$oci_ref" \
  --repo "$SOURCE_REPOSITORY" \
  --signer-workflow "$signer_workflow" \
  --source-digest "$REVISION" \
  --predicate-type "https://slsa.dev/provenance/v1" \
  --bundle-from-oci \
  --format json \
  > "${EVIDENCE_DIR}/provenance-verify.json"

jq -e 'type == "array" and length > 0' "${EVIDENCE_DIR}/provenance-verify.json" >/dev/null

log "Verificando attestation SBOM SPDX 2.3 desde OCI"
gh attestation verify "$oci_ref" \
  --repo "$SOURCE_REPOSITORY" \
  --signer-workflow "$signer_workflow" \
  --source-digest "$REVISION" \
  --predicate-type "https://spdx.dev/Document/v2.3" \
  --bundle-from-oci \
  --format json \
  > "${EVIDENCE_DIR}/sbom-attestation-verify.json"

jq -e 'type == "array" and length > 0' "${EVIDENCE_DIR}/sbom-attestation-verify.json" >/dev/null

log "Firma, provenance y SBOM attestados/verificados para ${image_ref}"
