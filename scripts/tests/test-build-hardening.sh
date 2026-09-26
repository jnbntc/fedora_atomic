#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

grep -Eq '^[[:space:]]+starship[[:space:]]+&&[[:space:]]+\\
  echo "FAIL: starship no está en la transacción rpm-ostree" >&2
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
grep -Fq -- '"${security_args[@]}"' "$workflow"

grep -Fq 'if [[ "${GITHUB_REF}" == "refs/heads/main" ]]' "$workflow" || {
  echo "FAIL: cache remoto no está restringido a main" >&2
  exit 1
}

grep -Fq "if: github.ref == 'refs/heads/main'" "$workflow" || {
  echo "FAIL: publicación de imagen no está restringida a main" >&2
  exit 1
}

echo "OK: hardening estático del build validado."
 Containerfile || {
  echo "FAIL: starship no está en la transacción rpm-ostree" >&2
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
grep -Fq -- '"${security_args[@]}"' "$workflow"

grep -Fq 'if [[ "${GITHUB_REF}" == "refs/heads/main" ]]' "$workflow" || {
  echo "FAIL: cache remoto no está restringido a main" >&2
  exit 1
}

grep -Fq "if: github.ref == 'refs/heads/main'" "$workflow" || {
  echo "FAIL: publicación de imagen no está restringida a main" >&2
  exit 1
}

echo "OK: hardening estático del build validado."
