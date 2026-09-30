#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

required_files=(
  "files/usr/libexec/fedora-power-profile"
  "files/usr/lib/systemd/system/fedora-power-profile.service"
  "files/etc/yum.repos.d/vscode.repo"
  "files/etc/profile.d/vscode-tune.sh"
  "files/etc/skel/.config/Code/User/settings.json"
  "files/etc/systemd/zram-generator.conf.d/ai-workload.conf"
  "files/etc/sysctl.d/99-ai-zram-tuning.conf"
  "files/etc/modprobe.d/iwlwifi.conf"
  "files/etc/udev/rules.d/99-battery.rules"
  "files/etc/tmpfiles.d/lenovo-conservation.conf"
  "files/usr/libexec/fedora-atomic-verified-update"
  "files/usr/lib/systemd/system/fedora-atomic-verified-update.service"
  "files/usr/lib/systemd/system/fedora-atomic-verified-update.timer"
)

for file in "${required_files[@]}"; do
  [[ -f "$file" ]] || {
    echo "FAIL: falta $file" >&2
    exit 1
  }
done

if grep -q 'echo -e' Containerfile; then
  echo "FAIL: Containerfile todavía genera configuración con echo -e" >&2
  exit 1
fi

grep -Fq 'COPY files/etc/yum.repos.d/vscode.repo /etc/yum.repos.d/vscode.repo' Containerfile || {
  echo "FAIL: falta COPY temprano de vscode.repo" >&2
  exit 1
}

grep -Fq 'COPY files/etc/ /etc/' Containerfile || {
  echo "FAIL: falta COPY declarativo de files/etc" >&2
  exit 1
}

grep -Fq 'COPY files/usr/ /usr/' Containerfile || {
  echo "FAIL: falta COPY declarativo de files/usr" >&2
  exit 1
}

python3 -m json.tool files/etc/skel/.config/Code/User/settings.json >/dev/null

python3 - <<'PY'
import json
from pathlib import Path

data = json.loads(Path("files/etc/skel/.config/Code/User/settings.json").read_text())
assert data["update.mode"] == "none"
assert data["telemetry.telemetryLevel"] == "off"
PY

grep -Fxq 'export VSCODE_DISABLE_TELEMETRY=1' files/etc/profile.d/vscode-tune.sh
grep -Fxq 'export DONT_PROMPT_WSL_INSTALL=1' files/etc/profile.d/vscode-tune.sh

grep -Fxq 'zram-size = ram' files/etc/systemd/zram-generator.conf.d/ai-workload.conf
grep -Fxq 'compression-algorithm = zstd' files/etc/systemd/zram-generator.conf.d/ai-workload.conf

grep -Fxq 'vm.swappiness = 180' files/etc/sysctl.d/99-ai-zram-tuning.conf
grep -Fxq 'vm.page-cluster = 0' files/etc/sysctl.d/99-ai-zram-tuning.conf
grep -Fxq 'vm.watermark_boost_factor = 0' files/etc/sysctl.d/99-ai-zram-tuning.conf

grep -Fxq 'options iwlwifi power_save=1' files/etc/modprobe.d/iwlwifi.conf

bash -n files/usr/libexec/fedora-power-profile
for state in 0 1; do
  grep -Fq "ATTR{online}==\"$state\"" files/etc/udev/rules.d/99-battery.rules
done
grep -Fc 'ACTION=="add|change"' files/etc/udev/rules.d/99-battery.rules | grep -qx 2
grep -Fc '/usr/bin/systemctl --no-block start fedora-power-profile.service' files/etc/udev/rules.d/99-battery.rules | grep -qx 2
if grep -REq 'powerprofilesctl|conservation_mode' files/etc/; then
  echo "FAIL: configuración de energía obsoleta" >&2
  exit 1
fi
grep -Fxq 'w /sys/class/power_supply/BAT*/charge_types - - - - Long_Life' files/etc/tmpfiles.d/lenovo-conservation.conf
for directive in 'Type=oneshot' 'Wants=tuned.service' 'After=tuned.service' 'ExecStart=/usr/libexec/fedora-power-profile'; do
  grep -Fxq "$directive" files/usr/lib/systemd/system/fedora-power-profile.service
done

grep -Fxq 'enabled=1' files/etc/yum.repos.d/vscode.repo
grep -Fxq 'gpgcheck=1' files/etc/yum.repos.d/vscode.repo

echo "OK: árbol declarativo files/etc validado."
