#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

# shellcheck source=../smoke/test-image.sh
source scripts/smoke/test-image.sh

extract_install_packages() {
  awk '
    /rpm-ostree install \\/ {
      in_block=1
      next
    }
    in_block {
      line=$0
      sub(/^[[:space:]]+/, "", line)
      if (line ~ /&& \\$/) {
        sub(/[[:space:]]+&& \\$/, "", line)
        print line
        exit
      }
      sub(/[[:space:]]+\\$/, "", line)
      print line
    }
  ' Containerfile | sed '/^$/d' | sort
}

extract_removed_packages() {
  awk '
    /rpm-ostree override remove \\/ {
      in_block=1
      next
    }
    in_block {
      line=$0
      sub(/^[[:space:]]+/, "", line)
      if (line ~ /&& \\$/) {
        sub(/[[:space:]]+&& \\$/, "", line)
        print line
        exit
      }
      sub(/[[:space:]]+\\$/, "", line)
      print line
    }
  ' Containerfile | sed '/^$/d' | sort
}

printf '%s\n' "${REQUIRED_PACKAGES[@]}" | sort > /tmp/smoke-required-packages
extract_install_packages > /tmp/containerfile-install-packages

if ! diff -u /tmp/containerfile-install-packages /tmp/smoke-required-packages; then
  echo "FAIL: REQUIRED_PACKAGES no coincide con rpm-ostree install" >&2
  exit 1
fi

printf '%s\n' "${FORBIDDEN_PACKAGES[@]}" | sort > /tmp/smoke-forbidden-packages
extract_removed_packages > /tmp/containerfile-removed-packages

if ! diff -u /tmp/containerfile-removed-packages /tmp/smoke-forbidden-packages; then
  echo "FAIL: FORBIDDEN_PACKAGES no coincide con rpm-ostree override remove" >&2
  exit 1
fi

container_starship_version="$(
  sed -n 's/^ARG STARSHIP_VERSION=//p' Containerfile | head -n1
)"

[[ "$container_starship_version" == "$EXPECTED_STARSHIP_VERSION" ]] || {
  echo "FAIL: Starship smoke=$EXPECTED_STARSHIP_VERSION Containerfile=$container_starship_version" >&2
  exit 1
}

workflow=".github/workflows/build.yml"
grep -Fq 'podman run --rm -i "$image_ref" bash -s -- --inside' scripts/smoke/test-image.sh || {
  echo "FAIL: runner interno de smoke no mantiene stdin abierto con podman -i" >&2
  exit 1
}

grep -Fq 'bash scripts/smoke/test-image.sh' "$workflow" || {
  echo "FAIL: build.yml no ejecuta artifact smoke tests" >&2
  exit 1
}

smoke_line="$(grep -n 'Artifact Smoke Tests' "$workflow" | head -n1 | cut -d: -f1)"
syft_line="$(grep -n 'Download pinned Syft' "$workflow" | head -n1 | cut -d: -f1)"
push_line="$(grep -n 'Push Built Image' "$workflow" | head -n1 | cut -d: -f1)"

[[ -n "$smoke_line" && -n "$syft_line" && -n "$push_line" ]] || {
  echo "FAIL: faltan etapas esperadas en build.yml" >&2
  exit 1
}

(( smoke_line < syft_line && smoke_line < push_line )) || {
  echo "FAIL: smoke tests deben ejecutarse antes de seguridad y push" >&2
  exit 1
}

grep -Fq 'security-evidence/artifact-smoke.txt' "$workflow" || {
  echo "FAIL: smoke report no se conserva como evidencia" >&2
  exit 1
}

grep -Fq '      - scripts/smoke/**' "$workflow" || {
  echo "FAIL: cambios del smoke test no disparan build en main" >&2
  exit 1
}

echo "OK: contrato de smoke tests sincronizado con Containerfile y pipeline."


if [[ -e ".github/workflows/stage6-probe.yml" ]]; then
  echo "FAIL: quedó el workflow temporal stage6-probe.yml" >&2
  exit 1
fi

echo "OK: no queda workflow temporal de Etapa 6."
