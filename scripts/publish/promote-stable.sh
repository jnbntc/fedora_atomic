#!/usr/bin/env bash
set -Eeuo pipefail

REPOSITORY=""
REVISION=""
SOURCE_RUN_ID=""
SOURCE_RUN_ATTEMPT=""
EVIDENCE_FILE="promotion-evidence/stable-promotion.json"
CANDIDATE_TAG="candidate"
STABLE_TAG="stable"

log()  { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die()  { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Falta el comando requerido: $1"
}

inspect_required() {
  local tag="$1"
  local err_file output

  err_file="$(mktemp)"
  if output="$(skopeo inspect "docker://${REPOSITORY}:${tag}" 2>"$err_file")"; then
    rm -f "$err_file"
    jq -e '.Digest | test("^sha256:[0-9a-f]{64}$")' <<<"$output" >/dev/null \
      || die "Digest inválido al inspeccionar ${tag}"
    printf '%s\n' "$output"
    return 0
  fi

  warn "No se pudo inspeccionar tag requerido ${tag}:"
  cat "$err_file" >&2
  rm -f "$err_file"
  return 1
}

inspect_optional_digest() {
  local tag="$1"
  local err_file output rc

  err_file="$(mktemp)"
  if output="$(skopeo inspect --format '{{.Digest}}' "docker://${REPOSITORY}:${tag}" 2>"$err_file")"; then
    rm -f "$err_file"
    printf '%s\n' "$output"
    return 0
  else
    rc=$?
  fi

  if grep -Eqi 'manifest unknown|name unknown|not found|404' "$err_file"; then
    rm -f "$err_file"
    return 1
  fi

  warn "No se pudo inspeccionar tag opcional ${tag}:"
  cat "$err_file" >&2
  rm -f "$err_file"
  return "$rc"
}

write_evidence() {
  local status="$1"
  local promoted="$2"
  local digest="$3"
  local candidate_digest="$4"
  local stable_before="$5"
  local stable_after="$6"
  local now

  mkdir -p "$(dirname "$EVIDENCE_FILE")"
  now="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"

  jq -n \
    --arg repository "$REPOSITORY" \
    --arg status "$status" \
    --argjson promoted "$promoted" \
    --arg digest "$digest" \
    --arg candidate_digest "$candidate_digest" \
    --arg stable_before "$stable_before" \
    --arg stable_after "$stable_after" \
    --arg revision "$REVISION" \
    --arg run_id "$SOURCE_RUN_ID" \
    --arg run_attempt "$SOURCE_RUN_ATTEMPT" \
    --arg recorded_at "$now" \
    '{
      schema_version: 1,
      repository: $repository,
      status: $status,
      promoted: $promoted,
      digest: $digest,
      candidate_digest: $candidate_digest,
      stable_before: (if $stable_before == "" then null else $stable_before end),
      stable_after: (if $stable_after == "" then null else $stable_after end),
      source_revision: $revision,
      source_build: {
        run_id: $run_id,
        run_attempt: $run_attempt
      },
      recorded_at: $recorded_at,
      channels: {
        candidate: "candidate",
        stable: "stable"
      }
    }' >"$EVIDENCE_FILE"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repository) REPOSITORY="$2"; shift 2 ;;
    --revision) REVISION="$2"; shift 2 ;;
    --source-run-id) SOURCE_RUN_ID="$2"; shift 2 ;;
    --source-run-attempt) SOURCE_RUN_ATTEMPT="$2"; shift 2 ;;
    --evidence-file) EVIDENCE_FILE="$2"; shift 2 ;;
    -h|--help)
      echo "Uso: promote-stable.sh --repository REPO --revision SHA40 --source-run-id ID --source-run-attempt N [--evidence-file PATH]"
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
[[ "$SOURCE_RUN_ID" =~ ^[0-9]+$ ]] || die "--source-run-id debe ser entero"
[[ "$SOURCE_RUN_ATTEMPT" =~ ^[0-9]+$ ]] || die "--source-run-attempt debe ser entero"

revision_tag="sha-${REVISION}"
revision_json="$(inspect_required "$revision_tag")" || die "Falta identidad inmutable ${revision_tag}"
candidate_json="$(inspect_required "$CANDIDATE_TAG")" || die "Falta canal ${CANDIDATE_TAG}"

revision_digest="$(jq -r '.Digest' <<<"$revision_json")"
candidate_digest="$(jq -r '.Digest' <<<"$candidate_json")"
image_revision="$(jq -r '.Labels["org.opencontainers.image.revision"] // empty' <<<"$revision_json")"

[[ "$image_revision" == "$REVISION" ]] \
  || die "Label OCI revision=${image_revision:-<vacío>} no coincide con ${REVISION}"

stable_before=""
if stable_before="$(inspect_optional_digest "$STABLE_TAG")"; then
  :
else
  rc=$?
  [[ "$rc" -eq 1 ]] || die "No se pudo determinar el estado de ${STABLE_TAG} (rc=${rc})"
  stable_before=""
fi

if [[ "$candidate_digest" != "$revision_digest" ]]; then
  warn "Promoción obsoleta: candidate=${candidate_digest}, build=${revision_digest}. No se toca stable."
  write_evidence "stale_candidate" false "$revision_digest" "$candidate_digest" "$stable_before" "$stable_before"
  {
    echo "### Stable promotion"
    echo
    echo "- Estado: **stale candidate — sin promoción**"
    echo "- Build: `${revision_digest}`"
    echo "- Candidate actual: `${candidate_digest}`"
  } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
  exit 0
fi

if [[ "$stable_before" == "$revision_digest" ]]; then
  log "stable ya apunta al digest validado: ${revision_digest}"
  write_evidence "already_stable" false "$revision_digest" "$candidate_digest" "$stable_before" "$stable_before"
  {
    echo "### Stable promotion"
    echo
    echo "- Estado: **already stable**"
    echo "- Digest: `${revision_digest}`"
  } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
  exit 0
fi

log "Promoviendo ${revision_tag} -> ${STABLE_TAG}"
skopeo copy "docker://${REPOSITORY}:${revision_tag}" "docker://${REPOSITORY}:${STABLE_TAG}"

stable_after="$(inspect_optional_digest "$STABLE_TAG")" \
  || die "No se pudo verificar stable después de la promoción"

[[ "$stable_after" == "$revision_digest" ]] \
  || die "stable quedó en digest inesperado: ${stable_after} != ${revision_digest}"

write_evidence "promoted" true "$revision_digest" "$candidate_digest" "$stable_before" "$stable_after"

log "Stable promovido: ${REPOSITORY}:stable -> ${stable_after}"
{
  echo "### Stable promotion"
  echo
  echo "- Estado: **promoted**"
  echo "- Digest: `${stable_after}`"
  echo "- Revision: `${REVISION}`"
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
