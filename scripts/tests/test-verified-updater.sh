#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="${ROOT_DIR}/files/usr/libexec/fedora-atomic-verified-update"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

BIN="${TMP_DIR}/bin"
STATE="${TMP_DIR}/state.json"
LOG="${TMP_DIR}/calls.log"
mkdir -p "$BIN"
: >"$LOG"

REV="0123456789abcdef0123456789abcdef01234567"
DIGEST="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
OLD="sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
REPO="ghcr.io/test/fedora_atomic"

cat >"${BIN}/skopeo" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'skopeo %s\n' "\$*" >>"$LOG"
cat <<'JSON'
{"Digest":"$DIGEST","Labels":{"org.opencontainers.image.revision":"$REV"}}
JSON
EOF

cat >"${BIN}/cosign" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'cosign %s\n' "$*" >>"${FAKE_LOG:?}"
[[ -z "${FAIL_COSIGN:-}" ]] || exit 1
exit 0
EOF

cat >"${BIN}/rpm-ostree" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'rpm-ostree %s\n' "$*" >>"${FAKE_LOG:?}"

if [[ "${1:-}" == "status" && "${2:-}" == "--json" ]]; then
  cat "${FAKE_STATE:?}"
  exit 0
fi

if [[ "${1:-}" == "cleanup" && "${2:-}" == "--pending" ]]; then
  jq '.deployments |= map(select(.staged != true))' "${FAKE_STATE}" >"${FAKE_STATE}.tmp"
  mv "${FAKE_STATE}.tmp" "${FAKE_STATE}"
  exit 0
fi

if [[ "${1:-}" == "rebase" ]]; then
  target="${2:?}"
  digest="${target##*@}"
  jq --arg d "$digest" --arg r "$target" '
    .deployments |= map(.staged = false)
    | .deployments = ([{
        booted:false,
        staged:true,
        "container-image-reference":$r,
        "container-image-reference-digest":$d
      }] + .deployments)
  ' "${FAKE_STATE}" >"${FAKE_STATE}.tmp"
  mv "${FAKE_STATE}.tmp" "${FAKE_STATE}"
  exit 0
fi

exit 2
EOF

chmod +x "${BIN}/skopeo" "${BIN}/cosign" "${BIN}/rpm-ostree"
export PATH="${BIN}:${PATH}"
export FAKE_LOG="$LOG"
export FAKE_STATE="$STATE"
export FEDORA_ATOMIC_ALLOW_ANY_TIME=1
export FEDORA_ATOMIC_ALLOW_NON_ROOT=1
export FEDORA_ATOMIC_REPOSITORY="$REPO"

# Caso 1: ya booted en stable -> verifica supply chain pero no rebasea.
cat >"$STATE" <<EOF
{"deployments":[
  {"booted":true,"staged":false,
   "container-image-reference":"ostree-unverified-registry:$REPO@$DIGEST",
   "container-image-reference-digest":"$DIGEST"}
]}
EOF
: >"$LOG"

bash "$SCRIPT" >/dev/null

[[ "$(grep -c '^cosign ' "$LOG")" -eq 3 ]] || {
  echo "FAIL: esperaba firma + 2 attestations" >&2
  exit 1
}

if grep -Fq 'rpm-ostree rebase ' "$LOG"; then
  echo "FAIL: rebaseó aunque stable ya estaba booted" >&2
  exit 1
fi

# Caso 2: nuevo stable -> rebase exacto por digest.
cat >"$STATE" <<EOF
{"deployments":[
  {"booted":true,"staged":false,
   "container-image-reference":"ostree-unverified-registry:$REPO@$OLD",
   "container-image-reference-digest":"$OLD"}
]}
EOF
: >"$LOG"

bash "$SCRIPT" >/dev/null

grep -Fq "rpm-ostree rebase ostree-unverified-registry:$REPO@$DIGEST" "$LOG" || {
  echo "FAIL: no rebaseó al digest verificado" >&2
  cat "$LOG" >&2
  exit 1
}

jq -e --arg d "$DIGEST" '
  any(.deployments[]; .staged == true and .["container-image-reference-digest"] == $d)
' "$STATE" >/dev/null

# Caso 3: staged gestionado viejo -> cleanup y reemplazo.
cat >"$STATE" <<EOF
{"deployments":[
  {"booted":false,"staged":true,
   "container-image-reference":"ostree-unverified-registry:$REPO@$OLD",
   "container-image-reference-digest":"$OLD"},
  {"booted":true,"staged":false,
   "container-image-reference":"ostree-unverified-registry:$REPO@$OLD",
   "container-image-reference-digest":"$OLD"}
]}
EOF
: >"$LOG"

bash "$SCRIPT" >/dev/null

grep -Fq 'rpm-ostree cleanup --pending' "$LOG"
grep -Fq "rpm-ostree rebase ostree-unverified-registry:$REPO@$DIGEST" "$LOG"

# Caso 4: staged ajeno -> fail closed.
cat >"$STATE" <<EOF
{"deployments":[
  {"booted":false,"staged":true,
   "container-image-reference":"ostree-unverified-registry:ghcr.io/otro/proyecto@$OLD",
   "container-image-reference-digest":"$OLD"},
  {"booted":true,"staged":false,
   "container-image-reference":"ostree-unverified-registry:$REPO@$OLD",
   "container-image-reference-digest":"$OLD"}
]}
EOF
: >"$LOG"

if bash "$SCRIPT" >/dev/null 2>&1; then
  echo "FAIL: aceptó staged ajeno" >&2
  exit 1
fi

if grep -Fq 'rpm-ostree rebase ' "$LOG"; then
  echo "FAIL: rebaseó pese a staged ajeno" >&2
  exit 1
fi

# Caso 5: falla de firma -> nunca rebasea.
cat >"$STATE" <<EOF
{"deployments":[
  {"booted":true,"staged":false,
   "container-image-reference":"ostree-unverified-registry:$REPO@$OLD",
   "container-image-reference-digest":"$OLD"}
]}
EOF
: >"$LOG"
export FAIL_COSIGN=1

if bash "$SCRIPT" >/dev/null 2>&1; then
  echo "FAIL: ignoró fallo Cosign" >&2
  exit 1
fi
unset FAIL_COSIGN

if grep -Fq 'rpm-ostree rebase ' "$LOG"; then
  echo "FAIL: rebaseó después de fallo criptográfico" >&2
  exit 1
fi

# Contrato estático del timer/servicio/build.
timer="${ROOT_DIR}/files/usr/lib/systemd/system/fedora-atomic-verified-update.timer"
service="${ROOT_DIR}/files/usr/lib/systemd/system/fedora-atomic-verified-update.service"
build="${ROOT_DIR}/.github/workflows/build.yml"
containerfile="${ROOT_DIR}/Containerfile"

grep -Fq 'OnCalendar=*-*-* 02:30:00' "$timer"
grep -Fq 'OnCalendar=*-*-* 18:30:00' "$timer"
grep -Fq 'Persistent=false' "$timer"
grep -Fq 'WakeSystem=false' "$timer"
grep -Fq 'ExecStart=/usr/libexec/fedora-atomic-verified-update' "$service"
grep -Fq 'Nice=10' "$service"
grep -Fq 'IOSchedulingClass=idle' "$service"
grep -Fq "cron: '17 19 * * *'" "$build"

grep -Fq 'systemctl enable fedora-atomic-verified-update.timer' "$containerfile"
if grep -Fq '/usr/lib/systemd/system/timers.target.wants/' "$containerfile"; then
  echo "FAIL: el timer verificado no debe habilitarse mediante vendor wants" >&2
  exit 1
fi

grep -Fq 'COSIGN_VERSION=3.1.3' "${ROOT_DIR}/Containerfile"
grep -Fq 'COSIGN_SHA256=4629c757b7618056f8ddd7e2625ae9fdd94c0372a65049520bc7d9df9efc7f71' "${ROOT_DIR}/Containerfile"

echo "OK: updater verificado, fail-closed y horarios fuera de jornada validados."
