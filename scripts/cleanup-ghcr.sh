#!/usr/bin/env bash
set -Eeuo pipefail

DRY_RUN=1
RETENTION_DAYS=14
KEEP_OLD_TAGGED=5
CACHE_RETENTION_DAYS=14
CACHE_KEEP_MIN=100
OWNER="${OWNER:-${GITHUB_REPOSITORY_OWNER:-}}"
PACKAGES=()
PLANNED=0
APPLIED=0

log()  { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die()  { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Uso:
  cleanup-ghcr.sh [--dry-run|--apply] [opciones]

Opciones:
  --dry-run                    Solo muestra qué borraría (default).
  --apply                      Ejecuta las eliminaciones.
  --owner OWNER                Usuario propietario del paquete GHCR.
  --retention-days N           Antigüedad mínima para builds etiquetados (default: 14).
  --keep-old-tagged N          Builds antiguos etiquetados a conservar (default: 5).
  --cache-retention-days N     Antigüedad mínima para cache etiquetado (default: 14).
  --cache-keep-min N           Mínimo de versiones cache etiquetadas a conservar (default: 100).
  --package NAME               Paquete a procesar. Se puede repetir.
  -h, --help                   Muestra esta ayuda.

Por defecto procesa:
  fedora_atomic
  fedora_atomic%2Fcache
EOF
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Falta el comando requerido: $1"
}

is_uint() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

fetch_versions() {
  local package="$1"
  local endpoint="/users/${OWNER}/packages/container/${package}/versions?per_page=100"
  local err_file raw

  err_file="$(mktemp)"

  if ! raw="$(gh api --paginate -H "Accept: application/vnd.github+json" "$endpoint" 2>"$err_file")"; then
    if grep -q 'HTTP 404' "$err_file"; then
      warn "El paquete ${package} no existe o no es visible para este token."
      rm -f "$err_file"
      printf '[]\n'
      return 0
    fi

    warn "Falló la consulta de versiones para ${package}:"
    cat "$err_file" >&2
    rm -f "$err_file"
    return 1
  fi

  rm -f "$err_file"

  if [[ -z "$raw" ]]; then
    printf '[]\n'
    return 0
  fi

  jq -s 'flatten' <<<"$raw"
}

delete_version() {
  local package="$1"
  local id="$2"
  local description="$3"
  local endpoint="/users/${OWNER}/packages/container/${package}/versions/${id}"
  local err_file

  PLANNED=$((PLANNED + 1))

  if (( DRY_RUN )); then
    log "[DRY-RUN] DELETE ${package} version=${id} (${description})"
    return 0
  fi

  err_file="$(mktemp)"

  if gh api --method DELETE "$endpoint" >/dev/null 2>"$err_file"; then
    APPLIED=$((APPLIED + 1))
    log "Eliminada ${package} version=${id} (${description})"
    rm -f "$err_file"
    return 0
  fi

  if grep -q 'HTTP 404' "$err_file"; then
    warn "La versión ${package}/${id} ya no existe; posible carrera, continúo."
    rm -f "$err_file"
    return 0
  fi

  warn "Falló DELETE de ${package}/${id}:"
  cat "$err_file" >&2
  rm -f "$err_file"
  return 1
}

clean_untagged() {
  local package="$1"
  local versions="$2"
  local row id updated
  local -a rows=()

  mapfile -t rows < <(
    jq -r '
      .[]
      | select(.metadata.container.tags == [])
      | [.id, .updated_at]
      | @tsv
    ' <<<"$versions"
  )

  for row in "${rows[@]}"; do
    IFS=$'\t' read -r id updated <<<"$row"
    delete_version "$package" "$id" "untagged, updated=${updated}"
  done
}

clean_main_tagged() {
  local versions="$1"
  local cutoff row id updated tags
  local -a rows=()

  cutoff="$(date -u -d "${RETENTION_DAYS} days ago" +'%Y-%m-%dT%H:%M:%SZ')"
  log "Política imagen: cutoff=${cutoff}; conservar ${KEEP_OLD_TAGGED} builds antiguos además de los recientes."

  mapfile -t rows < <(
    jq -r       --arg cutoff "$cutoff"       --argjson keep "$KEEP_OLD_TAGGED" '
        [
          .[]
          | select(
              (.metadata.container.tags | length) > 0
              and (.metadata.container.tags | index("latest") | not)
              and .updated_at < $cutoff
            )
        ]
        | sort_by(.updated_at)
        | reverse
        | .[$keep:]
        | .[]
        | [.id, (.metadata.container.tags | join(",")), .updated_at]
        | @tsv
      ' <<<"$versions"
  )

  for row in "${rows[@]}"; do
    IFS=$'\t' read -r id tags updated <<<"$row"
    delete_version "fedora_atomic" "$id" "tags=${tags}, updated=${updated}"
  done
}

clean_cache_tagged() {
  local versions="$1"
  local cutoff row id updated tags
  local -a rows=()

  cutoff="$(date -u -d "${CACHE_RETENTION_DAYS} days ago" +'%Y-%m-%dT%H:%M:%SZ')"
  log "Política cache: cutoff=${cutoff}; conservar al menos ${CACHE_KEEP_MIN} versiones etiquetadas más recientes."

  mapfile -t rows < <(
    jq -r       --arg cutoff "$cutoff"       --argjson keep "$CACHE_KEEP_MIN" '
        [
          .[]
          | select((.metadata.container.tags | length) > 0)
        ]
        | sort_by(.updated_at)
        | reverse
        | .[$keep:]
        | .[]
        | select(.updated_at < $cutoff)
        | [.id, (.metadata.container.tags | join(",")), .updated_at]
        | @tsv
      ' <<<"$versions"
  )

  for row in "${rows[@]}"; do
    IFS=$'\t' read -r id tags updated <<<"$row"
    delete_version "fedora_atomic%2Fcache" "$id" "cache tags=${tags}, updated=${updated}"
  done
}

clean_package() {
  local package="$1"
  local versions count

  log "Procesando paquete: ${package}"
  versions="$(fetch_versions "$package")"
  count="$(jq 'length' <<<"$versions")"

  if [[ "$count" -eq 0 ]]; then
    log "Sin versiones para ${package}."
    return 0
  fi

  log "Versiones encontradas: ${count}"

  clean_untagged "$package" "$versions"

  case "$package" in
    fedora_atomic)
      clean_main_tagged "$versions"
      ;;
    fedora_atomic%2Fcache)
      clean_cache_tagged "$versions"
      ;;
  esac
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --apply)
      DRY_RUN=0
      shift
      ;;
    --owner)
      [[ $# -ge 2 ]] || die "--owner requiere un valor"
      OWNER="$2"
      shift 2
      ;;
    --retention-days)
      [[ $# -ge 2 ]] || die "--retention-days requiere un valor"
      RETENTION_DAYS="$2"
      shift 2
      ;;
    --keep-old-tagged)
      [[ $# -ge 2 ]] || die "--keep-old-tagged requiere un valor"
      KEEP_OLD_TAGGED="$2"
      shift 2
      ;;
    --cache-retention-days)
      [[ $# -ge 2 ]] || die "--cache-retention-days requiere un valor"
      CACHE_RETENTION_DAYS="$2"
      shift 2
      ;;
    --cache-keep-min)
      [[ $# -ge 2 ]] || die "--cache-keep-min requiere un valor"
      CACHE_KEEP_MIN="$2"
      shift 2
      ;;
    --package)
      [[ $# -ge 2 ]] || die "--package requiere un valor"
      PACKAGES+=("$2")
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Opción desconocida: $1"
      ;;
  esac
done

require_cmd gh
require_cmd jq
require_cmd date

[[ -n "$OWNER" ]] || die "OWNER no definido. Use --owner o GITHUB_REPOSITORY_OWNER."
[[ -n "${GH_TOKEN:-}" ]] || die "GH_TOKEN no definido."
is_uint "$RETENTION_DAYS" || die "--retention-days debe ser un entero >= 0"
is_uint "$KEEP_OLD_TAGGED" || die "--keep-old-tagged debe ser un entero >= 0"
is_uint "$CACHE_RETENTION_DAYS" || die "--cache-retention-days debe ser un entero >= 0"
is_uint "$CACHE_KEEP_MIN" || die "--cache-keep-min debe ser un entero >= 0"

if [[ ${#PACKAGES[@]} -eq 0 ]]; then
  PACKAGES=("fedora_atomic" "fedora_atomic%2Fcache")
fi

if (( DRY_RUN )); then
  log "Modo DRY-RUN: no se borrará nada."
else
  log "Modo APPLY: las versiones seleccionadas serán eliminadas."
fi

for package in "${PACKAGES[@]}"; do
  clean_package "$package"
done

if (( DRY_RUN )); then
  mode="dry-run"
else
  mode="apply"
fi

log "Resumen: candidatas=${PLANNED}, eliminadas=${APPLIED}, modo=${mode}"
