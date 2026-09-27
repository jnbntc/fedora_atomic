#!/usr/bin/env bash
set -Eeuo pipefail

REPOSITORY="ghcr.io/jnbntc/fedora_atomic"
SOURCE_REPOSITORY="jnbntc/fedora_atomic"
CHANNEL="stable"
WORKFLOW_PATH=".github/workflows/build.yml"
EVIDENCE_DIR="recovery-evidence"

log() { printf '[INFO] %s\n' "$*"; }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Falta el comando requerido: $1"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repository) REPOSITORY="$2"; shift 2 ;;
    --source-repository) SOURCE_REPOSITORY="$2"; shift 2 ;;
    --channel) CHANNEL="$2"; shift 2 ;;
    --workflow-path) WORKFLOW_PATH="$2"; shift 2 ;;
    --evidence-dir) EVIDENCE_DIR="$2"; shift 2 ;;
    -h|--help)
      echo "Uso: verify-stable.sh [--repository REPO] [--source-repository OWNER/REPO] [--channel stable] [--evidence-dir DIR]"
      exit 0
      ;;
    *) die "Opción desconocida: $1" ;;
  esac
done

require_cmd skopeo
require_cmd jq
require_cmd cosign
require_cmd gh

if [[ -z "${GH_TOKEN:-}" ]]; then
  if token="$(gh auth token 2>/dev/null)" && [[ -n "$token" ]]; then
    export GH_TOKEN="$token"
  else
    die "GH_TOKEN no está definido y 'gh auth token' no devolvió credenciales"
  fi
fi

mkdir -p "$EVIDENCE_DIR"

inspect_json="$(skopeo inspect "docker://${REPOSITORY}:${CHANNEL}")"
digest="$(jq -r '.Digest // empty' <<<"$inspect_json")"
revision="$(jq -r '.Labels["org.opencontainers.image.revision"] // empty' <<<"$inspect_json")"

[[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || die "Digest OCI inválido para ${CHANNEL}: ${digest:-<vacío>}"
[[ "$revision" =~ ^[0-9a-f]{40}$ ]] || die "Label OCI revision inválida para ${CHANNEL}: ${revision:-<vacío>}"

log "Canal ${CHANNEL}: ${REPOSITORY}@${digest}"
log "Revision fuente: ${revision}"

bash "$(dirname "${BASH_SOURCE[0]}")/../security/verify-signed-image.sh" \
  --repository "$REPOSITORY" \
  --digest "$digest" \
  --revision "$revision" \
  --source-repository "$SOURCE_REPOSITORY" \
  --workflow-path "$WORKFLOW_PATH" \
  --evidence-dir "$EVIDENCE_DIR/supply-chain"

now="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
jq -n \
  --arg repository "$REPOSITORY" \
  --arg channel "$CHANNEL" \
  --arg digest "$digest" \
  --arg revision "$revision" \
  --arg verified_at "$now" \
  '{
    schema_version: 1,
    repository: $repository,
    channel: $channel,
    digest: $digest,
    source_revision: $revision,
    verified_at: $verified_at,
    verification: {
      cosign: true,
      slsa_provenance: true,
      spdx_attestation: true
    }
  }' >"$EVIDENCE_DIR/stable-resolution.json"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "digest=$digest"
    echo "revision=$revision"
  } >>"$GITHUB_OUTPUT"
fi

printf 'STABLE_REPOSITORY=%s\n' "$REPOSITORY"
printf 'STABLE_DIGEST=%s\n' "$digest"
printf 'STABLE_REVISION=%s\n' "$revision"
printf 'RPM_OSTREE_TARGET=ostree-unverified-registry:%s@%s\n' "$REPOSITORY" "$digest"

log "Stable verificado criptográficamente y fijado por digest."
