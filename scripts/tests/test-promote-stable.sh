#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="${ROOT_DIR}/scripts/publish/promote-stable.sh"
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

cat >"${FAKE_BIN}/skopeo" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'skopeo %s\n' "$*" >>"${FAKE_CALL_LOG:?}"

if [[ "${1:-}" == "inspect" ]]; then
  ref="${*: -1}"
  tag="${ref##*:}"

  if [[ "${FAKE_FATAL_TAG:-}" == "$tag" ]]; then
    echo "unauthorized: simulated" >&2
    exit 2
  fi

  row="$(awk -F'|' -v tag="$tag" '$1 == tag {print; exit}' "${FAKE_REMOTE_MAP:?}")"
  if [[ -z "$row" ]]; then
    echo "manifest unknown: simulated" >&2
    exit 1
  fi

  IFS='|' read -r _ digest revision <<<"$row"

  if [[ "$*" == *"--format"* ]]; then
    printf '%s\n' "$digest"
  else
    printf '{"Digest":"%s","Labels":{"org.opencontainers.image.revision":"%s"}}\n' "$digest" "$revision"
  fi
  exit 0
fi

if [[ "${1:-}" == "copy" ]]; then
  src="${2:?}"
  dst="${3:?}"
  src_tag="${src##*:}"
  dst_tag="${dst##*:}"

  row="$(awk -F'|' -v tag="$src_tag" '$1 == tag {print; exit}' "${FAKE_REMOTE_MAP:?}")"
  [[ -n "$row" ]] || exit 2
  IFS='|' read -r _ digest revision <<<"$row"

  tmp="${FAKE_REMOTE_MAP}.tmp"
  awk -F'|' -v tag="$dst_tag" '$1 != tag {print}' "${FAKE_REMOTE_MAP}" >"$tmp"
  printf '%s|%s|%s\n' "$dst_tag" "$digest" "$revision" >>"$tmp"
  mv "$tmp" "${FAKE_REMOTE_MAP}"
  exit 0
fi

exit 2
EOF
chmod +x "${FAKE_BIN}/skopeo"

export PATH="${FAKE_BIN}:${PATH}"
export FAKE_CALL_LOG="$CALL_LOG"
export FAKE_REMOTE_MAP="$REMOTE_MAP"

run_promote() {
  bash "$SCRIPT" \
    --repository "$REPO" \
    --revision "$REVISION" \
    --source-run-id "$1" \
    --source-run-attempt "$2" \
    --evidence-file "$3"
}

seed() {
  local run_id="$1"
  local build_digest="$2"
  local candidate_digest="$3"
  local revision="$4"

  : >"$REMOTE_MAP"
  printf 'run-%s-1|%s|%s\n' "$run_id" "$build_digest" "$revision" >>"$REMOTE_MAP"
  printf 'candidate|%s|%s\n' "$candidate_digest" "$revision" >>"$REMOTE_MAP"
}

# 1. Candidate actual: stable se mueve al digest validado.
seed 200 "$DIGEST" "$DIGEST" "$REVISION"
printf 'stable|%s|%s\n' "$OTHER_DIGEST" "$REVISION" >>"$REMOTE_MAP"
: >"$CALL_LOG"

ev1="${TMP_DIR}/promoted.json"
run_promote 200 1 "$ev1" >/dev/null

grep -Fq 'skopeo copy' "$CALL_LOG"
jq -e --arg digest "$DIGEST" '
  .status == "promoted"
  and .promoted == true
  and .digest == $digest
  and .stable_after == $digest
' "$ev1" >/dev/null

# 2. Stable ya está en el digest: no copia.
seed 201 "$DIGEST" "$DIGEST" "$REVISION"
printf 'stable|%s|%s\n' "$DIGEST" "$REVISION" >>"$REMOTE_MAP"
: >"$CALL_LOG"

ev2="${TMP_DIR}/already.json"
run_promote 201 1 "$ev2" >/dev/null

if grep -Fq 'skopeo copy' "$CALL_LOG"; then
  echo "FAIL: copió stable aunque ya apuntaba al digest" >&2
  exit 1
fi
jq -e '.status == "already_stable" and .promoted == false' "$ev2" >/dev/null

# 3. Candidate avanzó: un run viejo no puede pisar stable.
seed 202 "$DIGEST" "$OTHER_DIGEST" "$REVISION"
printf 'stable|%s|%s\n' "$OTHER_DIGEST" "$REVISION" >>"$REMOTE_MAP"
: >"$CALL_LOG"

ev3="${TMP_DIR}/stale.json"
run_promote 202 1 "$ev3" >/dev/null

if grep -Fq 'skopeo copy' "$CALL_LOG"; then
  echo "FAIL: un candidate obsoleto intentó promover stable" >&2
  exit 1
fi
jq -e --arg candidate "$OTHER_DIGEST" '
  .status == "stale_candidate"
  and .promoted == false
  and .candidate_digest == $candidate
' "$ev3" >/dev/null

# 4. Label OCI incorrecta: fail closed.
seed 203 "$DIGEST" "$DIGEST" "ffffffffffffffffffffffffffffffffffffffff"
: >"$CALL_LOG"

if run_promote 203 1 "${TMP_DIR}/bad-label.json" >/dev/null 2>&1; then
  echo "FAIL: revision OCI incorrecta fue aceptada" >&2
  exit 1
fi
if grep -Fq 'skopeo copy' "$CALL_LOG"; then
  echo "FAIL: promovió con revision OCI incorrecta" >&2
  exit 1
fi

# 5. Error de inspección de candidate: fail closed.
seed 204 "$DIGEST" "$DIGEST" "$REVISION"
: >"$CALL_LOG"
export FAKE_FATAL_TAG="candidate"

if run_promote 204 1 "${TMP_DIR}/fatal.json" >/dev/null 2>&1; then
  echo "FAIL: error remoto de candidate fue ignorado" >&2
  exit 1
fi
if grep -Fq 'skopeo copy' "$CALL_LOG"; then
  echo "FAIL: promovió después de error remoto" >&2
  exit 1
fi
unset FAKE_FATAL_TAG

echo "OK: promoción stable, stale-candidate y fail-closed validados."


# ---------------------------------------------------------------------------
# Contrato estático del workflow de promoción
# ---------------------------------------------------------------------------
workflow="${ROOT_DIR}/.github/workflows/promote-stable.yml"
build_workflow="${ROOT_DIR}/.github/workflows/build.yml"

grep -Fq 'workflow_run:' "$workflow" || {
  echo "FAIL: promoción no se dispara desde workflow_run" >&2
  exit 1
}

grep -Fq 'Fedora Atomic Core - Build & Security Gate' "$workflow" || {
  echo "FAIL: promoción no está ligada al workflow de build correcto" >&2
  exit 1
}

grep -Fq "github.event.workflow_run.conclusion == 'success'" "$workflow" || {
  echo "FAIL: promoción no exige build exitoso" >&2
  exit 1
}

grep -Fq "github.event.workflow_run.head_branch == 'main'" "$workflow" || {
  echo "FAIL: promoción no está limitada a main" >&2
  exit 1
}

grep -Fq 'group: fedora-atomic-release' "$workflow" || {
  echo "FAIL: promoción no usa el lock compartido de release" >&2
  exit 1
}

grep -Fq "github.ref == 'refs/heads/main' && 'release'" "$build_workflow" || {
  echo "FAIL: build de main no comparte el lock de release" >&2
  exit 1
}

grep -Fq "ref: \${{ github.event.workflow_run.head_sha }}" "$workflow" || {
  echo "FAIL: promoción no checkout-ea la revision exacta" >&2
  exit 1
}

grep -Fq "IMAGE_REF=\"\${IMAGE_NAME}:sha-\${REVISION}\"" "$workflow" || {
  echo "FAIL: promoción no valida la identidad inmutable sha-<commit>" >&2
  exit 1
}

grep -Fq 'bash scripts/smoke/test-image.sh' "$workflow" || {
  echo "FAIL: promoción no repite smoke tests" >&2
  exit 1
}

grep -Fq 'dnf5 --refresh advisory list' "$workflow" || {
  echo "FAIL: promoción no repite advisories Fedora" >&2
  exit 1
}

grep -Fq 'evaluate-fedora-advisories.sh' "$workflow" || {
  echo "FAIL: promoción no aplica el Fedora security gate" >&2
  exit 1
}

enforce_line="$(grep -n 'Enforce candidate validation' "$workflow" | cut -d: -f1)"
promote_line="$(grep -n 'Promote candidate to stable' "$workflow" | cut -d: -f1)"

[[ -n "$enforce_line" && -n "$promote_line" && "$enforce_line" -lt "$promote_line" ]] || {
  echo "FAIL: candidate debe validarse antes de promover stable" >&2
  exit 1
}

grep -Fq 'scripts/publish/promote-stable.sh' "$workflow" || {
  echo "FAIL: workflow no usa el promotor race-safe" >&2
  exit 1
}

echo "OK: contrato candidate → stable validado."
