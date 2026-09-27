#!/usr/bin/env bash
set -Eeuo pipefail

REPOSITORY="ghcr.io/jnbntc/fedora_atomic"
SOURCE_REPOSITORY="jnbntc/fedora_atomic"
EVIDENCE_DIR="recovery-evidence"
APPLY=0
REBOOT=0
ALLOW_LAYERED=0

log() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repository) REPOSITORY="$2"; shift 2 ;;
    --source-repository) SOURCE_REPOSITORY="$2"; shift 2 ;;
    --evidence-dir) EVIDENCE_DIR="$2"; shift 2 ;;
    --apply) APPLY=1; shift ;;
    --reboot) REBOOT=1; shift ;;
    --allow-layered) ALLOW_LAYERED=1; shift ;;
    -h|--help)
      cat <<'EOF'
Uso:
  rebase-stable.sh [--apply] [--reboot] [--allow-layered]

Por defecto verifica stable y muestra el rebase exacto sin modificar el host.
--apply          ejecuta rpm-ostree rebase al digest verificado
--reboot         reinicia después de un rebase exitoso; requiere --apply
--allow-layered  permite aplicar aunque se detecten Layered/Local/Override packages
EOF
      exit 0
      ;;
    *) die "Opción desconocida: $1" ;;
  esac
done

(( REBOOT == 0 || APPLY == 1 )) || die "--reboot requiere --apply"
command -v rpm-ostree >/dev/null 2>&1 || die "Este script debe ejecutarse en un host rpm-ostree"
command -v sudo >/dev/null 2>&1 || die "sudo no está disponible"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$EVIDENCE_DIR"

log "Capturando estado previo del host"
rpm-ostree status -v | tee "$EVIDENCE_DIR/rpm-ostree-status-before.txt" >/dev/null
rpm-ostree status --json >"$EVIDENCE_DIR/rpm-ostree-status-before.json"

status_text="$(cat "$EVIDENCE_DIR/rpm-ostree-status-before.txt")"
if grep -Eq '^[[:space:]]*(LayeredPackages|LocalPackages|RemovedBasePackages|BaseLocalReplacements|RemoteOverrides):' <<<"$status_text"; then
  warn "Se detectó estado local layered/override en rpm-ostree."
  warn "Ese estado no pertenece a la imagen base y debe formar parte de tu plan de recuperación."
  (( ALLOW_LAYERED == 1 )) || die "Usá --allow-layered después de revisar rpm-ostree-status-before.txt"
fi

verify_output="$(
  bash "$script_dir/verify-stable.sh" \
    --repository "$REPOSITORY" \
    --source-repository "$SOURCE_REPOSITORY" \
    --evidence-dir "$EVIDENCE_DIR"
)"

printf '%s\n' "$verify_output"

digest="$(awk -F= '$1 == "STABLE_DIGEST" {print $2}' <<<"$verify_output")"
revision="$(awk -F= '$1 == "STABLE_REVISION" {print $2}' <<<"$verify_output")"

[[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || die "No se pudo resolver un digest verificado"
[[ "$revision" =~ ^[0-9a-f]{40}$ ]] || die "No se pudo resolver una revision verificada"

target="ostree-unverified-registry:${REPOSITORY}@${digest}"

cat <<EOF

Stable verificado:
  revision: $revision
  digest:   $digest

Target rpm-ostree:
  $target
EOF

if (( APPLY == 0 )); then
  cat <<EOF

DRY-RUN: no se modificó el host.

Para aplicar:
  bash $0 --apply$([[ $ALLOW_LAYERED -eq 1 ]] && printf ' --allow-layered')

Después revisá:
  rpm-ostree status

Y reiniciá cuando estés conforme:
  sudo systemctl reboot
EOF
  exit 0
fi

log "Aplicando rebase al digest previamente verificado"
sudo rpm-ostree rebase "$target"

rpm-ostree status -v | tee "$EVIDENCE_DIR/rpm-ostree-status-after.txt"

if (( REBOOT == 1 )); then
  log "Rebase preparado; reiniciando por solicitud explícita"
  sudo systemctl reboot
else
  log "Rebase preparado. No se reinicia automáticamente."
fi
