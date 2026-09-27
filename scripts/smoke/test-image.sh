#!/usr/bin/env bash
set -Eeuo pipefail

EXPECTED_FEDORA_VERSION="44"
EXPECTED_FEDORA_ID="fedora"
EXPECTED_STARSHIP_VERSION="1.26.0"

REQUIRED_PACKAGES=(
  code
  virt-manager
  libvirt-daemon-kvm
  libvirt-client
  swtpm
  btop
  tmux
  zsh
  cockpit
  cockpit-podman
  cockpit-machines
  cockpit-system
  distrobox
  fira-code-fonts
  jetbrains-mono-fonts
  tailscale
  intel-compute-runtime
  libva-intel-media-driver
  oneapi-level-zero
  oneapi-level-zero-devel
  intel-gpu-tools
  clinfo
  vulkan-tools
  restic
  qemu-system-x86
  edk2-ovmf
  evtest
  thermald
  zsh-autosuggestions
  zsh-syntax-highlighting
  steam-devices
)

FORBIDDEN_PACKAGES=(
  firefox
  firefox-langpacks
)

REQUIRED_COMMANDS=(
  code
  virt-manager
  virsh
  swtpm
  btop
  tmux
  zsh
  cockpit-bridge
  distrobox
  tailscale
  intel_gpu_top
  clinfo
  vulkaninfo
  restic
  qemu-system-x86_64
  evtest
  thermald
  podman
  rpm-ostree
  dnf5
  starship
)

ENABLED_UNITS=(
  podman-auto-update.timer
  tailscaled.service
  thermald.service
  libvirtd.service
)

fail() {
  printf '[FAIL] %s\n' "$*" >&2
  exit 1
}

info() {
  printf '[INFO] %s\n' "$*"
}

inside_image() {
  source /usr/lib/os-release

  [[ "${ID:-}" == "$EXPECTED_FEDORA_ID" ]]     || fail "ID=${ID:-<vacío>} (esperado: $EXPECTED_FEDORA_ID)"
  [[ "${VERSION_ID:-}" == "$EXPECTED_FEDORA_VERSION" ]]     || fail "VERSION_ID=${VERSION_ID:-<vacío>} (esperado: $EXPECTED_FEDORA_VERSION)"

  test -f /usr/share/rpm/rpmdb.sqlite     || fail "rpmdb OSTree ausente en /usr/share/rpm/rpmdb.sqlite"

  missing_packages=()
  for package in "${REQUIRED_PACKAGES[@]}"; do
    if ! rpm -q "$package" >/dev/null 2>&1; then
      missing_packages+=("$package")
    fi
  done

  if (( ${#missing_packages[@]} > 0 )); then
    printf '[FAIL] Paquetes requeridos ausentes: %s\n' "${missing_packages[*]}" >&2
    exit 1
  fi

  for package in "${FORBIDDEN_PACKAGES[@]}"; do
    if rpm -q "$package" >/dev/null 2>&1; then
      fail "Paquete prohibido presente: $package"
    fi
  done

  missing_commands=()
  for command_name in "${REQUIRED_COMMANDS[@]}"; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      missing_commands+=("$command_name")
    fi
  done

  if (( ${#missing_commands[@]} > 0 )); then
    printf '[FAIL] Comandos requeridos ausentes: %s\n' "${missing_commands[*]}" >&2
    exit 1
  fi

  actual_starship_version="$(starship --version | awk 'NR == 1 {print $2}')"
  [[ "$actual_starship_version" == "$EXPECTED_STARSHIP_VERSION" ]]     || fail "Starship $actual_starship_version (esperado: $EXPECTED_STARSHIP_VERSION)"

  test -f /etc/yum.repos.d/vscode.repo || fail "vscode.repo ausente"
  test -f /etc/yum.repos.d/tailscale.repo || fail "tailscale.repo ausente"

  for unit in "${ENABLED_UNITS[@]}"; do
    unit_link="/usr/lib/systemd/system/multi-user.target.wants/$unit"
    expected_target="/usr/lib/systemd/system/$unit"

    [[ -L "$unit_link" ]] || fail "Unidad no habilitada por symlink: $unit"
    [[ "$(readlink "$unit_link")" == "$expected_target" ]]       || fail "Symlink inesperado para $unit: $(readlink "$unit_link")"
    test -f "$expected_target" || fail "Unit file ausente: $expected_target"
  done

  test -d /ostree || fail "Árbol OSTree ausente"
  test -x /usr/bin/starship || fail "/usr/bin/starship no es ejecutable"

  info "Fedora $VERSION_ID, paquetes, comandos, Starship y unidades: OK"
}

compare_declared_config() {
  local rootfs="$1"
  local expected_root="$2"
  local count=0

  [[ -d "$rootfs/etc" ]] || fail "rootfs/etc ausente"
  [[ -d "$expected_root" ]] || fail "árbol esperado ausente: $expected_root"

  while IFS= read -r -d '' source_file; do
    relative="${source_file#"$expected_root"/}"
    image_file="$rootfs/etc/$relative"

    [[ -f "$image_file" ]] || fail "Configuración ausente en imagen: /etc/$relative"
    cmp -s "$source_file" "$image_file"       || fail "Configuración distinta de IaC: /etc/$relative"

    count=$((count + 1))
  done < <(find "$expected_root" -type f -print0 | sort -z)

  (( count > 0 )) || fail "No se encontraron archivos declarativos para validar"
  info "Configuración declarativa comparada byte a byte: $count archivos OK"
}

host_mode() {
  local image_ref="${1:-}"
  local rootfs="${2:-rootfs}"
  local expected_root="${3:-files/etc}"
  local script_path

  [[ -n "$image_ref" ]] || fail "Uso: $0 IMAGE_REF [ROOTFS] [EXPECTED_CONFIG_ROOT]"
  command -v podman >/dev/null 2>&1 || fail "podman no está disponible"
  podman image exists "$image_ref" || fail "Imagen local inexistente: $image_ref"

  test -f "$rootfs/usr/lib/os-release" || fail "os-release ausente en rootfs"
  test -f "$rootfs/usr/share/rpm/rpmdb.sqlite" || fail "rpmdb ausente en rootfs"
  test -x "$rootfs/usr/bin/starship" || fail "Starship ausente/no ejecutable en rootfs"

  compare_declared_config "$rootfs" "$expected_root"

  script_path="$(readlink -f "${BASH_SOURCE[0]}")"
  podman run --rm "$image_ref" bash -s -- --inside < "$script_path"

  {
    echo "### Artifact smoke tests"
    echo
    echo "- Fedora **$EXPECTED_FEDORA_VERSION**: OK"
    echo "- Paquetes requeridos: **${#REQUIRED_PACKAGES[@]}** OK"
    echo "- Paquetes prohibidos: **${#FORBIDDEN_PACKAGES[@]}** ausentes"
    echo "- Comandos requeridos: **${#REQUIRED_COMMANDS[@]}** OK"
    echo "- Unidades habilitadas: **${#ENABLED_UNITS[@]}** OK"
    echo "- Starship: **$EXPECTED_STARSHIP_VERSION**"
    echo "- Configuración IaC: comparación byte a byte OK"
  } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

  info "Artifact smoke tests: PASS"
}

main() {
  if [[ "${1:-}" == "--inside" ]]; then
    inside_image
    return
  fi

  host_mode "$@"
}

if [[ "${1:-}" == "--inside" || "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
