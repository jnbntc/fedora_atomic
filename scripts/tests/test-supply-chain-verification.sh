#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="${ROOT_DIR}/scripts/security/verify-signed-image.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

BIN="${TMP_DIR}/bin"
LOG="${TMP_DIR}/calls.log"
mkdir -p "$BIN"
: >"$LOG"

REV="0123456789abcdef0123456789abcdef01234567"
DIGEST="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
REPO="ghcr.io/test/fedora_atomic"
SOURCE="test/fedora_atomic"

cat >"${BIN}/cosign" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'cosign %s\n' "$*" >>"${FAKE_LOG:?}"
[[ -z "${FAIL_COSIGN:-}" ]] || exit 1
printf '[{"critical":{"identity":{"docker-reference":"test"}}}]\n'
EOF

cat >"${BIN}/gh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'gh %s\n' "$*" >>"${FAKE_LOG:?}"
[[ -z "${FAIL_GH:-}" ]] || exit 1
printf '[{"verificationResult":{"statement":{"predicateType":"ok"}}}]\n'
EOF

chmod +x "${BIN}/cosign" "${BIN}/gh"
export PATH="${BIN}:${PATH}"
export FAKE_LOG="$LOG"
export GH_TOKEN="test-token"

bash "$SCRIPT" \
  --repository "$REPO" \
  --digest "$DIGEST" \
  --revision "$REV" \
  --source-repository "$SOURCE" \
  --evidence-dir "${TMP_DIR}/evidence" >/dev/null

grep -Fq -- '--certificate-identity https://github.com/test/fedora_atomic/.github/workflows/build.yml@refs/heads/main' "$LOG"
grep -Fq -- '--predicate-type https://slsa.dev/provenance/v1' "$LOG"
grep -Fq -- '--predicate-type https://spdx.dev/Document/v2.3' "$LOG"
grep -Fq -- '--bundle-from-oci' "$LOG"
grep -Fq -- "--source-digest $REV" "$LOG"

export FAIL_COSIGN=1
if bash "$SCRIPT" --repository "$REPO" --digest "$DIGEST" --revision "$REV" --source-repository "$SOURCE" >/dev/null 2>&1; then
  echo "FAIL: ignoró fallo Cosign" >&2
  exit 1
fi
unset FAIL_COSIGN

export FAIL_GH=1
if bash "$SCRIPT" --repository "$REPO" --digest "$DIGEST" --revision "$REV" --source-repository "$SOURCE" >/dev/null 2>&1; then
  echo "FAIL: ignoró fallo de attestation" >&2
  exit 1
fi
unset FAIL_GH

echo "OK: verificación de firma, provenance y SBOM falla cerrado."


# ---------------------------------------------------------------------------
# Contrato estático de Etapa 9
# ---------------------------------------------------------------------------
build_workflow="${ROOT_DIR}/.github/workflows/build.yml"
promote_workflow="${ROOT_DIR}/.github/workflows/promote-stable.yml"
cleanup_script="${ROOT_DIR}/scripts/cleanup-ghcr.sh"

grep -Fq -- '--defer-channels' "$build_workflow" || {
  echo "FAIL: build no difiere candidate/latest hasta después de firma" >&2
  exit 1
}

grep -Fq 'id-token: write' "$build_workflow" || {
  echo "FAIL: falta permiso OIDC para firma keyless" >&2
  exit 1
}

grep -Fq 'attestations: write' "$build_workflow" || {
  echo "FAIL: falta permiso para generar attestations" >&2
  exit 1
}

grep -Fq 'sigstore/cosign-installer@6f9f17788090df1f26f669e9d70d6ae9567deba6' "$build_workflow" || {
  echo "FAIL: Cosign installer no está pinneado al SHA esperado" >&2
  exit 1
}

grep -Fq 'cosign-release: v3.1.3' "$build_workflow" || {
  echo "FAIL: Cosign no está pinneado a v3.1.3" >&2
  exit 1
}

grep -Fq 'actions/attest-build-provenance@4d101475d8b20a2381f78447822ac1eab6504dd8' "$build_workflow" || {
  echo "FAIL: build provenance action no está pinneada" >&2
  exit 1
}

grep -Fq 'actions/attest@1e69f48acb82d1966a394da916b4c1698aa569d6' "$build_workflow" || {
  echo "FAIL: SBOM attestation action no está pinneada" >&2
  exit 1
}

verify_line="$(grep -n 'Verify signature and attestations' "$build_workflow" | cut -d: -f1)"
channels_line="$(grep -n 'Publish candidate and latest' "$build_workflow" | cut -d: -f1)"

[[ -n "$verify_line" && -n "$channels_line" && "$verify_line" -lt "$channels_line" ]] || {
  echo "FAIL: candidate/latest deben moverse después de verificar supply chain" >&2
  exit 1
}

promotion_verify_line="$(grep -n 'Verify candidate supply-chain evidence' "$promote_workflow" | cut -d: -f1)"
promotion_stable_line="$(grep -n 'Promote candidate to stable' "$promote_workflow" | cut -d: -f1)"

[[ -n "$promotion_verify_line" && -n "$promotion_stable_line" && "$promotion_verify_line" -lt "$promotion_stable_line" ]] || {
  echo "FAIL: stable debe verificar firma/provenance antes de promover" >&2
  exit 1
}

grep -Fq 'Versiones untagged del paquete principal se preservan' "$cleanup_script" || {
  echo "FAIL: cleanup no protege posibles referrers/signatures untagged" >&2
  exit 1
}

echo "OK: contrato estático de firma, provenance y promoción verificado."
