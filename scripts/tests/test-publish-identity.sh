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
  local run_id="$1"
  local attempt="$2"
  local identity_file="$3"
  shift 3

  bash "$SCRIPT" \
    --local-image localhost/fedora:latest \
    --repository "$REPO" \
    --date 20260929 \
    --revision "$REVISION" \
    --run-id "$run_id" \
    --run-attempt "$attempt" \
    --identity-file "$identity_file" \
    "$@"
}

# 1. Publicación normal: la identidad inmutable es el run exacto.
identity_1="${TMP_DIR}/identity-1.json"
run_publish 100 1 "$identity_1" >/dev/null

for tag in "run-100-1" "candidate" "latest"; do
  grep -Fq "${REPO}:${tag}" "$CALL_LOG" || {
    echo "FAIL: no publicó tag $tag" >&2
    exit 1
  }
done

if grep -Eq "${REPO}:(sha-${REVISION}|20260929-${REVISION:0:12})" "$CALL_LOG"; then
  echo "FAIL: volvió a publicar identidades ambiguas por commit/fecha" >&2
  exit 1
fi

[[ "$(grep -c '^podman push ' "$CALL_LOG")" -eq 3 ]] || {
  echo "FAIL: primera publicación esperaba run tag + candidate + latest" >&2
  cat "$CALL_LOG" >&2
  exit 1
}

jq -e --arg digest "$DIGEST" --arg rev "$REVISION" '
  .digest == $digest
  and .source_revision == $rev
  and .tags.immutable == ["run-100-1"]
  and .tags.mutable == ["candidate", "latest"]
  and .github_run.id == "100"
  and .github_run.attempt == "1"
' "$identity_1" >/dev/null

# 2. El mismo commit puede reconstruirse a otro digest en otra ejecución.
: >"$REMOTE_MAP"
: >"$CALL_LOG"
export FAKE_DIGEST="$OTHER_DIGEST"

identity_2="${TMP_DIR}/identity-2.json"
run_publish 101 1 "$identity_2" >/dev/null

jq -e --arg digest "$OTHER_DIGEST" --arg rev "$REVISION" '
  .digest == $digest
  and .source_revision == $rev
  and .tags.immutable == ["run-101-1"]
' "$identity_2" >/dev/null

grep -Fq "${REPO}:run-101-1" "$CALL_LOG"

# 3. Un run tag sí es inmutable: si ya existe, se bloquea.
cat >"$REMOTE_MAP" <<EOF
run-102-1 $DIGEST
EOF
: >"$CALL_LOG"
export FAKE_DIGEST="$OTHER_DIGEST"

if run_publish 102 1 "${TMP_DIR}/identity-duplicate-run.json" >/dev/null 2>&1; then
  echo "FAIL: reutilizó un run tag ya existente" >&2
  exit 1
fi

if grep -q '^podman push ' "$CALL_LOG"; then
  echo "FAIL: hubo push después de detectar run tag duplicado" >&2
  exit 1
fi

# 4. Error remoto no se interpreta como ausencia.
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

# 5. La label OCI debe corresponder al commit fuente.
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

# 6. Publicación diferida crea solo la identidad del run.
: >"$REMOTE_MAP"
: >"$CALL_LOG"
export FAKE_REVISION="$REVISION"
export FAKE_DIGEST="$DIGEST"

identity_6="${TMP_DIR}/identity-deferred.json"
run_publish 105 1 "$identity_6" --defer-channels >/dev/null

grep -Fq "${REPO}:run-105-1" "$CALL_LOG"

if grep -Eq "${REPO}:(candidate|latest)" "$CALL_LOG"; then
  echo "FAIL: publicación diferida movió candidate/latest" >&2
  cat "$CALL_LOG" >&2
  exit 1
fi

[[ "$(grep -c '^podman push ' "$CALL_LOG")" -eq 1 ]] || {
  echo "FAIL: publicación diferida esperaba un único push inmutable" >&2
  cat "$CALL_LOG" >&2
  exit 1
}

jq -e '
  .channels_deferred == true
  and .tags.immutable == ["run-105-1"]
' "$identity_6" >/dev/null

echo "OK: identidad OCI por run, rebuild no hermético y fail-closed validados."
