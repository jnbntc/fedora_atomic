#!/usr/bin/env bash
set -Eeuo pipefail

REPOSITORY=""
REVISION=""
DIGEST=""
EVIDENCE_FILE="signing-evidence/channel-publication.json"

log() { printf '[INFO] %s\n' "$*"; }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Falta el comando requerido: $1"
}

inspect_digest() {
  local tag="$1"
  skopeo inspect --format '{{.Digest}}' "docker://${REPOSITORY}:${tag}"
}

copy_and_verify() {
  local source_tag="$1"
  local target_tag="$2"
  local after

  skopeo copy "docker://${REPOSITORY}:${source_tag}" "docker://${REPOSITORY}:${target_tag}"
  after="$(inspect_digest "$target_tag")"
  [[ "$after" == "$DIGEST" ]] \
    || die "${target_tag} quedó en digest inesperado: ${after} != ${DIGEST}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repository) REPOSITORY="$2"; shift 2 ;;
    --revision) REVISION="$2"; shift 2 ;;
    --digest) DIGEST="$2"; shift 2 ;;
    --evidence-file) EVIDENCE_FILE="$2"; shift 2 ;;
    -h|--help)
      echo "Uso: publish-channels.sh --repository REPO --revision SHA40 --digest sha256:... [--evidence-file PATH]"
      exit 0
      ;;
    *) die "Opción desconocida: $1" ;;
  esac
done

require_cmd skopeo
require_cmd jq
require_cmd date

[[ -n "$REPOSITORY" ]] || die "--repository es obligatorio"
[[ "$REVISION" =~ ^[0-9a-f]{40}$ ]] || die "--revision debe ser SHA Git de 40 hex"
[[ "$DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || die "--digest debe ser SHA-256 OCI"

revision_tag="sha-${REVISION}"
source_digest="$(inspect_digest "$revision_tag")"
[[ "$source_digest" == "$DIGEST" ]] \
  || die "La identidad ${revision_tag} apunta a ${source_digest}, esperado ${DIGEST}"

log "Moviendo candidate al digest firmado"
copy_and_verify "$revision_tag" "candidate"

log "Moviendo latest al digest firmado"
copy_and_verify "$revision_tag" "latest"

mkdir -p "$(dirname "$EVIDENCE_FILE")"
now="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"

jq -n \
  --arg repository "$REPOSITORY" \
  --arg revision "$REVISION" \
  --arg digest "$DIGEST" \
  --arg recorded_at "$now" \
  '{
    schema_version: 1,
    repository: $repository,
    source_revision: $revision,
    digest: $digest,
    recorded_at: $recorded_at,
    channels: {
      candidate: $digest,
      latest: $digest
    }
  }' >"$EVIDENCE_FILE"

log "Canales publicados: candidate/latest -> ${DIGEST}"
