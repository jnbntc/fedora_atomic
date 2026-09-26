#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

required_files=(
  "files/etc/yum.repos.d/vscode.repo"
  "files/etc/profile.d/vscode-tune.sh"
  "files/etc/skel/.config/Code/User/settings.json"
  "files/etc/systemd/zram-generator.conf.d/ai-workload.conf"
  "files/etc/sysctl.d/99-ai-zram-tuning.conf"
  "files/etc/modprobe.d/iwlwifi.conf"
  "files/etc/udev/rules.d/99-battery.rules"
  "files/etc/tmpfiles.d/lenovo-conservation.conf"
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

grep -Fq 'ATTR{online}=="0"' files/etc/udev/rules.d/99-battery.rules
grep -Fq 'powerprofilesctl set power-saver' files/etc/udev/rules.d/99-battery.rules
grep -Fq 'ATTR{online}=="1"' files/etc/udev/rules.d/99-battery.rules
grep -Fq 'powerprofilesctl set balanced' files/etc/udev/rules.d/99-battery.rules

grep -Fxq 'w /sys/bus/platform/drivers/ideapad_acpi/VPC2004:00/conservation_mode - - - - 1'   files/etc/tmpfiles.d/lenovo-conservation.conf

grep -Fxq 'enabled=1' files/etc/yum.repos.d/vscode.repo
grep -Fxq 'gpgcheck=1' files/etc/yum.repos.d/vscode.repo

echo "OK: árbol declarativo files/etc validado."
