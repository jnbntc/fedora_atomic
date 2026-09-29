#!/usr/bin/env bash
set -Eeuo pipefail

LOCAL_IMAGE=""
REPOSITORY=""
BUILD_DATE=""
REVISION=""
RUN_ID=""
RUN_ATTEMPT=""
IDENTITY_FILE="security-evidence/image-identity.json"
DEFER_CHANNELS=0

log()  { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die()  { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Uso:
  publish-image.sh \
    --local-image IMAGE \
    --repository REPO \
    --date YYYYMMDD \
    --revision GIT_SHA40 \
    --run-id ID \
    --run-attempt N \
    [--identity-file PATH]

Identidad OCI:
  run-<run_id>-<attempt>   tag inmutable por ejecución
  sha256:...               identidad primaria del artefacto

Canales mutables:
  candidate
  latest

Opción:
  --defer-channels   Publica solo identidades inmutables; candidate/latest quedan para una fase posterior.
EOF
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Falta el comando requerido: $1"
}

remote_digest() {
  local tag="$1"
  local err_file output rc

  err_file="$(mktemp)"

  if output="$(skopeo inspect --format '{{.Digest}}' "docker://${REPOSITORY}:${tag}" 2>"$err_file")"; then
    rm -f "$err_file"
    printf '%s\n' "$output"
    return 0
  fi

  rc=$?

  if grep -Eqi 'manifest unknown|name unknown|not found|404' "$err_file"; then
    rm -f "$err_file"
    return 1
  fi

  warn "No se pudo verificar el tag remoto ${tag}:"
  cat "$err_file" >&2
  rm -f "$err_file"
  return "$rc"
}

push_tag_and_verify() {
  local tag="$1"
  local expected_digest="$2"
  local digest_file pushed_digest

  digest_file="$(mktemp)"
  podman tag "$LOCAL_IMAGE" "${REPOSITORY}:${tag}"
  podman push --digestfile="$digest_file" "${REPOSITORY}:${tag}"
  pushed_digest="$(tr -d '\r\n' <"$digest_file")"
  rm -f "$digest_file"

  [[ "$pushed_digest" == "$expected_digest" ]] \
    || die "Digest inesperado al publicar ${tag}: ${pushed_digest} != ${expected_digest}"
}

publish_run_identity() {
  local tag="$1"
  local existing rc digest_file digest

  if existing="$(remote_digest "$tag")"; then
    die "El tag de ejecución ${tag} ya existe (${existing}); RUN_ID/RUN_ATTEMPT deberían ser únicos"
  else
    rc=$?
  fi

  [[ "$rc" -eq 1 ]] || die "No se pudo comprobar ausencia de ${tag} (rc=${rc})"

  digest_file="$(mktemp)"
  podman tag "$LOCAL_IMAGE" "${REPOSITORY}:${tag}"
  podman push --digestfile="$digest_file" "${REPOSITORY}:${tag}"
  digest="$(tr -d '\r\n' <"$digest_file")"
  rm -f "$digest_file"

  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] \
    || die "Digest OCI inválido tras publicar ${tag}: ${digest}"

  printf '%s\n' "$digest"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --local-image) LOCAL_IMAGE="$2"; shift 2 ;;
    --repository) REPOSITORY="$2"; shift 2 ;;
    --date) BUILD_DATE="$2"; shift 2 ;;
    --revision) REVISION="$2"; shift 2 ;;
    --run-id) RUN_ID="$2"; shift 2 ;;
    --run-attempt) RUN_ATTEMPT="$2"; shift 2 ;;
    --identity-file) IDENTITY_FILE="$2"; shift 2 ;;
    --defer-channels) DEFER_CHANNELS=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Opción desconocida: $1" ;;
  esac
done

require_cmd podman
require_cmd skopeo
require_cmd jq
require_cmd date

[[ -n "$LOCAL_IMAGE" ]] || die "--local-image es obligatorio"
[[ -n "$REPOSITORY" ]] || die "--repository es obligatorio"
[[ "$BUILD_DATE" =~ ^[0-9]{8}$ ]] || die "--date debe tener formato YYYYMMDD"
[[ "$REVISION" =~ ^[0-9a-f]{40}$ ]] || die "--revision debe ser SHA Git de 40 hex"
[[ "$RUN_ID" =~ ^[0-9]+$ ]] || die "--run-id debe ser entero"
[[ "$RUN_ATTEMPT" =~ ^[0-9]+$ ]] || die "--run-attempt debe ser entero"

podman image exists "$LOCAL_IMAGE" || die "Imagen local inexistente: $LOCAL_IMAGE"

image_revision="$(podman image inspect --format '{{ index .Labels "org.opencontainers.image.revision" }}' "$LOCAL_IMAGE")"
[[ "$image_revision" == "$REVISION" ]] \
  || die "Label OCI revision=${image_revision:-<vacío>} no coincide con ${REVISION}"

short_sha="${REVISION:0:12}"
run_tag="run-${RUN_ID}-${RUN_ATTEMPT}"

log "Publicando identidad inmutable de ejecución: ${run_tag}"
candidate_digest="$(publish_run_identity "$run_tag")"

if (( DEFER_CHANNELS )); then
  log "Canales mutables diferidos: candidate/latest se moverán después de firma y attestations."
else
  log "Actualizando canal mutable candidate"
  push_tag_and_verify "candidate" "$candidate_digest"

  log "Actualizando alias mutable latest al final"
  push_tag_and_verify "latest" "$candidate_digest"
fi

mkdir -p "$(dirname "$IDENTITY_FILE")"
generated_at="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"

jq -n \
  --arg repository "$REPOSITORY" \
  --arg digest "$candidate_digest" \
  --arg revision "$REVISION" \
  --arg short_revision "$short_sha" \
  --arg build_date "$BUILD_DATE" \
  --arg run_id "$RUN_ID" \
  --arg run_attempt "$RUN_ATTEMPT" \
  --arg generated_at "$generated_at" \
  --arg run_tag "$run_tag" \
  --arg defer_channels "$DEFER_CHANNELS" \
  '{
    schema_version: 1,
    repository: $repository,
    digest: $digest,
    source_revision: $revision,
    source_revision_short: $short_revision,
    build_date_utc: $build_date,
    github_run: {id: $run_id, attempt: $run_attempt},
    generated_at: $generated_at,
    tags: {
      immutable: [$run_tag],
      mutable: ["candidate", "latest"]
    },
    channels_deferred: ($defer_channels == "1")
  }' >"$IDENTITY_FILE"

log "Identidad publicada: ${REPOSITORY}@${candidate_digest}"
log "Tag inmutable de ejecución: ${run_tag}"
if (( DEFER_CHANNELS )); then
  log "Aliases mutables diferidos: candidate, latest"
else
  log "Aliases mutables: candidate, latest"
fi
