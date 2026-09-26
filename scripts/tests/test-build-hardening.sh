#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

grep -Fq 'ARG STARSHIP_VERSION=1.26.0' Containerfile || {
  echo "FAIL: falta versión pinneada de Starship" >&2
  exit 1
}

grep -Fq 'ARG STARSHIP_SHA256=321f0dd7af8340a5f2e6a8fec6538a04f617486f9ec70d878f91c09cd8deef22' Containerfile || {
  echo "FAIL: falta checksum pinneado de Starship" >&2
  exit 1
}

grep -Fq "sha256sum -c -" Containerfile || {
  echo "FAIL: Starship se descarga sin validar SHA-256" >&2
  exit 1
}

grep -Fq '/usr/bin/starship --version' Containerfile || {
  echo "FAIL: falta smoke check del binario Starship" >&2
  exit 1
}

if grep -Eq 'starship\.rs/install\.sh|curl[^|]*\|[[:space:]]*sh' Containerfile; then
  echo "FAIL: queda un instalador remoto ejecutado con curl | sh" >&2
  exit 1
fi

workflow=".github/workflows/build.yml"

for profile in   stable   no-cap-all   no-seccomp-unconfined   no-label-disable   podman-defaults
do
  grep -Fq "$profile" "$workflow" || {
    echo "FAIL: falta privilege_profile=$profile" >&2
    exit 1
  }
done

grep -Fq -- '--security-opt seccomp=unconfined' "$workflow"
grep -Fq -- '--security-opt label=disable' "$workflow"
grep -Fq -- '--cap-add=ALL' "$workflow"
grep -Fq "\"\${security_args[@]}\"" "$workflow"

grep -Fq "if [[ \"\${GITHUB_REF}\" == \"refs/heads/main\" ]]" "$workflow" || {
  echo "FAIL: cache remoto no está restringido a main" >&2
  exit 1
}

grep -Fq "if: github.ref == 'refs/heads/main'" "$workflow" || {
  echo "FAIL: publicación de imagen no está restringida a main" >&2
  exit 1
}

echo "OK: hardening estático del build validado."
