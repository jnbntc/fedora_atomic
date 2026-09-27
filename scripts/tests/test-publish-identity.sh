#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="${ROOT_DIR}/scripts/publish/publish-image.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FAKE_BIN="${TMP_DIR}/bin"
REMOTE_MAP="${TMP_DIR}/remote.tsv"
CALL_LOG="${TMP_DIR}/calls.log"
mkdir -p "$FAKE_BIN"
: >"$REMOTE_MAP"
: >"$CALL_LOG"

REVISION="0123456789abcdef0123456789abcdef01234567"
DIGEST="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
OTHER_DIGEST="sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
REPO="ghcr.io/test/fedora_atomic"

cat >"${FAKE_BIN}/podman" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'podman %s\n' "$*" >>"${FAKE_CALL_LOG:?}"

if [[ "${1:-}" == "image" && "${2:-}" == "exists" ]]; then exit 0; fi
if [[ "${1:-}" == "image" && "${2:-}" == "inspect" ]]; then printf '%s\n' "${FAKE_REVISION:?}"; exit 0; fi
if [[ "${1:-}" == "tag" ]]; then exit 0; fi

if [[ "${1:-}" == "push" ]]; then
  digest_file=""
  for arg in "$@"; do
    case "$arg" in
      --digestfile=*) digest_file="${arg#--digestfile=}" ;;
    esac
  done
  [[ -n "$digest_file" ]] || exit 2
  printf '%s\n' "${FAKE_DIGEST:?}" >"$digest_file"
  exit 0
fi

exit 2
EOF

cat >"${FAKE_BIN}/skopeo" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'skopeo %s\n' "$*" >>"${FAKE_CALL_LOG:?}"

if [[ -n "${FAKE_SKOPEO_FATAL:-}" ]]; then
  echo "unauthorized: simulated failure" >&2
  exit 2
fi

ref="${*: -1}"
tag="${ref##*:}"
match="$(awk -v tag="$tag" '$1 == tag {print $2; exit}' "${FAKE_REMOTE_MAP:?}")"

if [[ -n "$match" ]]; then
  printf '%s\n' "$match"
  exit 0
fi

echo "manifest unknown: simulated missing tag" >&2
exit 1
EOF

chmod +x "${FAKE_BIN}/podman" "${FAKE_BIN}/skopeo"
export PATH="${FAKE_BIN}:${PATH}"
export FAKE_CALL_LOG="$CALL_LOG"
export FAKE_REMOTE_MAP="$REMOTE_MAP"
export FAKE_REVISION="$REVISION"
export FAKE_DIGEST="$DIGEST"

run_publish() {
  bash "$SCRIPT" \
    --local-image localhost/fedora:latest \
    --repository "$REPO" \
    --date 20260927 \
    --revision "$REVISION" \
    --run-id "$1" \
    --run-attempt "$2" \
    --identity-file "$3"
}

identity_1="${TMP_DIR}/identity-1.json"
run_publish 100 1 "$identity_1" >/dev/null

for tag in "run-100-1" "sha-${REVISION}" "20260927-${REVISION:0:12}" "latest"; do
  grep -Fq "${REPO}:${tag}" "$CALL_LOG" || {
    echo "FAIL: no publicó tag $tag" >&2
    exit 1
  }
done

[[ "$(grep -c '^podman push ' "$CALL_LOG")" -eq 4 ]] || {
  echo "FAIL: primera publicación esperaba 4 pushes" >&2
  cat "$CALL_LOG" >&2
  exit 1
}

jq -e --arg digest "$DIGEST" --arg rev "$REVISION" '
  .digest == $digest
  and .source_revision == $rev
  and (.tags.immutable | length) == 3
  and .tags.mutable == ["latest"]
' "$identity_1" >/dev/null

cat >"$REMOTE_MAP" <<EOF
sha-${REVISION} $DIGEST
20260927-${REVISION:0:12} $DIGEST
EOF
: >"$CALL_LOG"

run_publish 101 1 "${TMP_DIR}/identity-2.json" >/dev/null

[[ "$(grep -c '^podman push ' "$CALL_LOG")" -eq 2 ]] || {
  echo "FAIL: reutilización esperaba solo run tag + latest" >&2
  cat "$CALL_LOG" >&2
  exit 1
}

cat >"$REMOTE_MAP" <<EOF
sha-${REVISION} $OTHER_DIGEST
EOF
: >"$CALL_LOG"

if run_publish 102 1 "${TMP_DIR}/identity-conflict.json" >/dev/null 2>&1; then
  echo "FAIL: conflicto de digest no bloqueó publicación" >&2
  exit 1
fi

if grep -Fq "${REPO}:latest" "$CALL_LOG"; then
  echo "FAIL: latest se movió pese al conflicto" >&2
  exit 1
fi

grep -Fq "${REPO}:run-102-1" "$CALL_LOG"

: >"$REMOTE_MAP"
: >"$CALL_LOG"
export FAKE_SKOPEO_FATAL=1

if run_publish 103 1 "${TMP_DIR}/identity-auth.json" >/dev/null 2>&1; then
  echo "FAIL: error remoto fue tratado como ausencia" >&2
  exit 1
fi

if grep -q '^podman push ' "$CALL_LOG"; then
  echo "FAIL: hubo push después de error remoto" >&2
  exit 1
fi
unset FAKE_SKOPEO_FATAL

: >"$CALL_LOG"
export FAKE_REVISION="ffffffffffffffffffffffffffffffffffffffff"

if run_publish 104 1 "${TMP_DIR}/identity-label.json" >/dev/null 2>&1; then
  echo "FAIL: revision OCI incorrecta fue aceptada" >&2
  exit 1
fi

if grep -q '^podman push ' "$CALL_LOG"; then
  echo "FAIL: tocó registro con revision OCI incorrecta" >&2
  exit 1
fi

echo "OK: identidad OCI inmutable, conflicto y fail-closed validados."
