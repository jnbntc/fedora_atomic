#!/usr/bin/env bash
set -Eeuo pipefail

OUTPUT_ROOT="${1:-recovery-snapshots}"
STAMP="$(date -u +'%Y%m%dT%H%M%SZ')"
OUT="${OUTPUT_ROOT}/${STAMP}"

log() { printf '[INFO] %s\n' "$*"; }

mkdir -p "$OUT"

if command -v rpm-ostree >/dev/null 2>&1; then
  rpm-ostree status -v >"$OUT/rpm-ostree-status.txt"
  rpm-ostree status --json >"$OUT/rpm-ostree-status.json"
fi

if command -v rpm >/dev/null 2>&1; then
  rpm -qa --qf '%{NAME}\t%{EPOCHNUM}:%{VERSION}-%{RELEASE}\t%{ARCH}\n' \
    | sort >"$OUT/rpm-packages.tsv"
fi

if command -v flatpak >/dev/null 2>&1; then
  flatpak list --columns=application,branch,origin 2>/dev/null \
    | sort >"$OUT/flatpaks.tsv" || true
fi

if command -v systemctl >/dev/null 2>&1; then
  systemctl --failed --no-pager >"$OUT/system-failed-units.txt" 2>&1 || true
  systemctl --user --failed --no-pager >"$OUT/user-failed-units.txt" 2>&1 || true
  systemctl is-enabled rpm-ostreed-automatic.timer >"$OUT/rpm-ostreed-timer-enabled.txt" 2>&1 || true
  systemctl list-timers rpm-ostreed-automatic.timer --all --no-pager \
    >"$OUT/rpm-ostreed-timer-status.txt" 2>&1 || true
fi

if command -v tuned-adm >/dev/null 2>&1; then
  tuned-adm active >"$OUT/tuned-active-profile.txt" 2>&1 || true
fi

if [[ -r /etc/rpm-ostreed.conf ]]; then
  cp --preserve=mode,timestamps /etc/rpm-ostreed.conf "$OUT/rpm-ostreed.conf"
fi

if [[ -d /etc/systemd/system/rpm-ostreed-automatic.timer.d ]]; then
  find /etc/systemd/system/rpm-ostreed-automatic.timer.d \
    -maxdepth 1 -type f -printf '%f\n' | sort \
    >"$OUT/rpm-ostreed-timer-dropins.txt"
fi

if [[ -d /etc/yum.repos.d ]]; then
  find /etc/yum.repos.d -maxdepth 1 -type f -printf '%f\n' | sort \
    >"$OUT/yum-repo-filenames.txt"
fi

cat >"$OUT/README.txt" <<EOF
Host recovery snapshot: $STAMP UTC

Este snapshot es inventario, NO backup de datos de usuario.

Incluye:
- rpm-ostree status y JSON
- inventario RPM
- Flatpaks (si existen)
- unidades fallidas del sistema (system-failed-units.txt)
- unidades fallidas del usuario (user-failed-units.txt; registra errores si no hay user bus)
- perfil TuneD activo, si tuned-adm existe (tuned-active-profile.txt)
- estado del timer rpm-ostreed
- rpm-ostreed.conf
- nombres de repos YUM (no su contenido)

No recopila:
- claves SSH
- tokens
- contraseñas
- /etc/shadow
- authfiles de registries
- contenido de $HOME
EOF

log "Snapshot creado en: $OUT"
log "Guardalo fuera del host junto con tu backup normal."
