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
