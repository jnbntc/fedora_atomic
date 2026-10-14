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
[[ -z "\${FAIL_SKOPEO:-}" ]] || exit 1
if [[ -n "\${MOVE_CLOCK_TO:-}" ]]; then
  printf '%s\n' "\$MOVE_CLOCK_TO" >"\$FAKE_CLOCK"
fi
if [[ "\${DISCONNECT_POWER:-0}" == 1 ]]; then
  printf '0\n' >"\${POWER_SUPPLY_ROOT}/AC/online"
fi
cat <<'JSON'
{"Digest":"$DIGEST","Labels":{"org.opencontainers.image.revision":"$REV"}}
JSON
EOF

cat >"${BIN}/cosign" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'cosign %s\n' "$*" >>"${FAKE_LOG:?}"
if [[ "${FAIL_COSIGN:-}" == 1 || ( -n "${FAIL_COSIGN:-}" && "$*" == *"${FAIL_COSIGN}"* ) ]]; then
  exit 1
fi
exit 0
EOF

cat >"${BIN}/rpm-ostree" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'rpm-ostree %s\n' "$*" >>"${FAKE_LOG:?}"

if [[ "${1:-}" == "status" && "${2:-}" == "--json" ]]; then
  [[ "${FAIL_STATUS:-0}" != 1 ]] || exit 1
  cat "${FAKE_STATE:?}"
  exit 0
fi

if [[ "${1:-}" == "cleanup" && "${2:-}" == "--pending" ]]; then
  jq '.deployments |= map(select(.staged != true))' "${FAKE_STATE}" >"${FAKE_STATE}.tmp"
  mv "${FAKE_STATE}.tmp" "${FAKE_STATE}"
  exit 0
fi

if [[ "${1:-}" == "rebase" ]]; then
  [[ "${FAIL_REBASE:-0}" != 1 ]] || exit 1
  target="${2:?}"
  digest="${target##*@}"
  [[ "${WRONG_STAGE:-0}" != 1 ]] || digest="sha256:unexpected"
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
export FEDORA_ATOMIC_STATE_DIR="${TMP_DIR}/updater-state"
export POWER_SUPPLY_ROOT="${TMP_DIR}/power"

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
grep -Fq 'Persistent=true' "$timer"
grep -Fq 'WakeSystem=false' "$timer"
grep -Fq 'OnBootSec=10min' "$timer"
grep -Fq 'OnCalendar=*-*-* *:00,30:00' "$timer"
# Parser real de systemd, además de los contratos de texto.
systemd-analyze calendar '*-*-* *:00,30:00' >/dev/null
grep -Fq 'StateDirectory=fedora-atomic-verified-update' "$service"
grep -Fq 'StateDirectoryMode=0700' "$service"
grep -Fq 'ExecStart=/usr/libexec/fedora-atomic-verified-update' "$service"
grep -Fq 'Nice=10' "$service"
grep -Fq 'IOSchedulingClass=idle' "$service"
grep -Fq "cron: '17 19 * * *'" "$build"

grep -Fq 'systemctl enable fedora-atomic-verified-update.timer' "$containerfile"
if grep -Fq 'fedora-atomic-verified-update.timer /usr/lib/systemd/system/timers.target.wants/' "$containerfile"; then
  echo "FAIL: el timer verificado no debe habilitarse mediante vendor wants" >&2
  exit 1
fi

grep -Fq 'COSIGN_VERSION=3.1.3' "${ROOT_DIR}/Containerfile"
grep -Fq 'COSIGN_SHA256=4629c757b7618056f8ddd7e2625ae9fdd94c0372a65049520bc7d9df9efc7f71' "${ROOT_DIR}/Containerfile"

# Reloj y energía deterministas: ninguna prueba usa rpm-ostree ni red reales.
REAL_DATE="$(command -v date)"
export REAL_DATE
export TZ=America/Argentina/Buenos_Aires
export FAKE_CLOCK="${TMP_DIR}/clock"
cat >"${BIN}/date" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
exec "$REAL_DATE" -d "$(cat "${FAKE_CLOCK:?}")" "$@"
EOF
chmod +x "${BIN}/date"
export FEDORA_ATOMIC_ALLOW_ANY_TIME=0

set_stamp() {
  "$REAL_DATE" -d "$2" +%s >"${FEDORA_ATOMIC_STATE_DIR}/$1"
}

reset_policy() {
  rm -rf "$FEDORA_ATOMIC_STATE_DIR" "$POWER_SUPPLY_ROOT"
  mkdir -p "$FEDORA_ATOMIC_STATE_DIR" "${POWER_SUPPLY_ROOT}/AC"
  printf 'Mains\n' >"${POWER_SUPPLY_ROOT}/AC/type"
  printf '1\n' >"${POWER_SUPPLY_ROOT}/AC/online"
  printf '%s\n' "$1" >"$FAKE_CLOCK"
  unset FAIL_SKOPEO FAIL_COSIGN MOVE_CLOCK_TO DISCONNECT_POWER FAIL_STATUS FAIL_REBASE WRONG_STAGE
  cat >"$STATE" <<EOF
{"deployments":[{"booted":true,"staged":false,
"container-image-reference":"ostree-unverified-registry:$REPO@$OLD",
"container-image-reference-digest":"$OLD"}]}
EOF
  : >"$LOG"
}

expect_deferred() {
  bash "$SCRIPT" >"${TMP_DIR}/output" 2>&1
  if [[ -s "$LOG" ]]; then
    echo "FAIL: un diferimiento llamó a herramientas de actualización" >&2
    cat "$LOG" "${TMP_DIR}/output" >&2
    exit 1
  fi
}

expect_staged() {
  bash "$SCRIPT" >"${TMP_DIR}/output" 2>&1
  grep -Fq "rpm-ostree rebase ostree-unverified-registry:$REPO@$DIGEST" "$LOG"
  [[ "$(cat "${FEDORA_ATOMIC_STATE_DIR}/last-success")" == "$(date +%s)" ]]
}

expect_no_stage() {
  if grep -Eq '^rpm-ostree (rebase|cleanup)' "$LOG"; then
    echo "FAIL: se modificó el deployment tras cambiar la guarda" >&2
    exit 1
  fi
}

# Bordes de las ventanas originales, incluso con éxito reciente.
for hhmm in 02:20 03:10 18:20 19:10; do
  reset_policy "2026-10-14 $hhmm:00"
  set_stamp last-success "2026-10-14 $hhmm:00"
  expect_staged
  grep -Fq 'Política autorizada: window.' "${TMP_DIR}/output"
done

# Catch-up al volver tarde, por la noche y fines de semana.
for clock in '2026-10-14 03:11:00' '2026-10-14 07:59:00' \
             '2026-10-14 19:11:00' '2026-10-14 23:30:00' \
             '2026-10-17 12:00:00' '2026-10-18 12:00:00'; do
  reset_policy "$clock"
  expect_staged
  grep -Fq 'Política autorizada: catch-up.' "${TMP_DIR}/output"
done

# Jornada protegida, incluso el primer arranque sin historial.
for hhmm in 08:00 12:00 18:19; do
  reset_policy "2026-10-14 $hhmm:00"
  expect_deferred
  [[ -f "${FEDORA_ATOMIC_STATE_DIR}/first-seen" ]]
  [[ ! -f "${FEDORA_ATOMIC_STATE_DIR}/last-success" ]]
  [[ ! -f "${FEDORA_ATOMIC_STATE_DIR}/last-attempt" ]]
done

# Edad de éxito: 71:59:59 difiere, 72 h habilita sólo con alimentación externa.
reset_policy '2026-10-14 12:00:00'
set_stamp last-success '2026-10-11 12:00:01'
expect_deferred
set_stamp last-success '2026-10-11 12:00:00'
expect_staged
grep -Fq 'Política autorizada: stale-recovery.' "${TMP_DIR}/output"

# Batería, energía desconocida o inválida no autorizan la excepción laboral.
for online in 0 unknown 2; do
  reset_policy '2026-10-14 12:00:00'
  set_stamp last-success '2026-10-10 12:00:00'
  printf '%s\n' "$online" >"${POWER_SUPPLY_ROOT}/AC/online"
  expect_deferred
done
reset_policy '2026-10-14 12:00:00'
set_stamp last-success '2026-10-10 12:00:00'
rm -rf "$POWER_SUPPLY_ROOT"
expect_deferred
# USB online también es alimentación externa.
reset_policy '2026-10-14 12:00:00'
set_stamp last-success '2026-10-10 12:00:00'
printf 'USB_C\n' >"${POWER_SUPPLY_ROOT}/AC/type"
expect_staged

# Sin ningún éxito, first-seen conserva la edad entre arranques/intentos.
reset_policy '2026-10-14 12:00:00'
set_stamp first-seen '2026-10-11 12:00:00'
expect_staged

# Éxito reciente ahorra red fuera de las ventanas; borde exacto de 6 h.
reset_policy '2026-10-14 23:30:00'
set_stamp last-success '2026-10-14 17:30:01'
expect_deferred
set_stamp last-success '2026-10-14 17:30:00'
expect_staged

# Red caída: no rejuvenece el éxito y reintenta fuera de jornada a los 30 min.
reset_policy '2026-10-14 20:00:00'
set_stamp last-success '2026-10-13 20:00:00'
export FAIL_SKOPEO=1
if bash "$SCRIPT" >/dev/null 2>&1; then
  echo 'FAIL: ignoró error de red' >&2
  exit 1
fi
[[ "$(cat "${FEDORA_ATOMIC_STATE_DIR}/last-success")" == "$("$REAL_DATE" -d '2026-10-13 20:00:00' +%s)" ]]
unset FAIL_SKOPEO
: >"$LOG"
printf '2026-10-14 20:29:59\n' >"$FAKE_CLOCK"
expect_deferred
printf '2026-10-14 20:30:00\n' >"$FAKE_CLOCK"
expect_staged

# Firma o cualquiera de las dos attestations fallida: no stage ni éxito.
for failure in 1 https://slsa.dev/provenance/v1 https://spdx.dev/Document/v2.3; do
  reset_policy '2026-10-14 20:00:00'
  export FAIL_COSIGN="$failure"
  if bash "$SCRIPT" >/dev/null 2>&1; then
    echo "FAIL: ignoró fallo criptográfico $failure" >&2
    exit 1
  fi
  expect_no_stage
  [[ ! -f "${FEDORA_ATOMIC_STATE_DIR}/last-success" ]]
done

# Errores de rpm-ostree / postcondición fallida tampoco registran éxito.
for failure in FAIL_STATUS FAIL_REBASE WRONG_STAGE; do
  reset_policy '2026-10-14 20:00:00'
  export "$failure=1"
  if bash "$SCRIPT" >/dev/null 2>&1; then
    echo "FAIL: ignoró $failure" >&2
    exit 1
  fi
  [[ ! -f "${FEDORA_ATOMIC_STATE_DIR}/last-success" ]]
done
reset_policy '2026-10-14 20:00:00'
jq --arg d "$OLD" '.deployments = ([{booted:false,staged:true,
  "container-image-reference":"ostree-unverified-registry:ghcr.io/foreign/image",
  "container-image-reference-digest":$d}] + .deployments)' "$STATE" >"${STATE}.tmp"
mv "${STATE}.tmp" "$STATE"
if bash "$SCRIPT" >/dev/null 2>&1; then
  echo 'FAIL: aceptó staged ajeno durante catch-up' >&2
  exit 1
fi
expect_no_stage
[[ ! -f "${FEDORA_ATOMIC_STATE_DIR}/last-success" ]]

# Recuperación laboral fallida: máximo un intento cada 6 h, incluso tras boot.
reset_policy '2026-10-14 09:00:00'
set_stamp last-success '2026-10-10 09:00:00'
export FAIL_COSIGN=1
if bash "$SCRIPT" >/dev/null 2>&1; then exit 1; fi
unset FAIL_COSIGN
: >"$LOG"
printf '2026-10-14 14:59:59\n' >"$FAKE_CLOCK"
expect_deferred
printf '2026-10-14 15:00:00\n' >"$FAKE_CLOCK"
expect_staged

# Reloj atrasado / timestamps corruptos: reiniciar el plazo, nunca forzar stage.
for invalid in garbage -1 0 99999999999999999999999999999999999999 99999999999; do
  reset_policy '2026-10-14 12:00:00'
  set_stamp first-seen '2026-10-10 12:00:00'
  printf '%s\n' "$invalid" >"${FEDORA_ATOMIC_STATE_DIR}/last-success"
  expect_deferred
  [[ ! -f "${FEDORA_ATOMIC_STATE_DIR}/last-success" ]]
  [[ "$(cat "${FEDORA_ATOMIC_STATE_DIR}/first-seen")" == "$(date +%s)" ]]
done
reset_policy '2026-10-14 12:00:00'
printf 'garbage\n' >"${FEDORA_ATOMIC_STATE_DIR}/first-seen"
expect_deferred

# Verificación que cruza 08:00: no cleanup/rebase y no declara éxito.
reset_policy '2026-10-14 07:59:00'
set_stamp last-success '2026-10-13 20:00:00'
jq '.deployments = ([.deployments[0] | .booted=false | .staged=true] + .deployments)' \
  "$STATE" >"${STATE}.tmp"
mv "${STATE}.tmp" "$STATE"
export MOVE_CLOCK_TO='2026-10-14 08:00:00'
bash "$SCRIPT" >"${TMP_DIR}/output" 2>&1
expect_no_stage
grep -Fq 'stage diferido' "${TMP_DIR}/output"
[[ "$(cat "${FEDORA_ATOMIC_STATE_DIR}/last-success")" == "$("$REAL_DATE" -d '2026-10-13 20:00:00' +%s)" ]]

# AC desconectado durante recuperación: tampoco modifica deployments.
reset_policy '2026-10-14 12:00:00'
set_stamp last-success '2026-10-10 12:00:00'
export DISCONNECT_POWER=1
bash "$SCRIPT" >"${TMP_DIR}/output" 2>&1
expect_no_stage
grep -Fq 'stage diferido' "${TMP_DIR}/output"

# Un stable ya booted o staged cuenta como comprobación exitosa, sin rebase.
for field in booted staged; do
  reset_policy '2026-10-14 20:00:00'
  jq --arg d "$DIGEST" --arg f "$field" \
    '.deployments[0] |= (.booted=false | .[$f]=true | .["container-image-reference-digest"]=$d)' \
    "$STATE" >"${STATE}.tmp"
  mv "${STATE}.tmp" "$STATE"
  bash "$SCRIPT" >/dev/null
  expect_no_stage
  [[ "$(cat "${FEDORA_ATOMIC_STATE_DIR}/last-success")" == "$(date +%s)" ]]
done

# Override administrativo mantiene verificación, estado y lock compartidos.
reset_policy '2026-10-14 12:00:00'
printf '0\n' >"${POWER_SUPPLY_ROOT}/AC/online"
FEDORA_ATOMIC_ALLOW_ANY_TIME=1 expect_staged
reset_policy '2026-10-14 20:00:00'
exec 8>"${FEDORA_ATOMIC_STATE_DIR}/lock"
flock -n 8
expect_deferred
flock -u 8
exec 8>&-

echo "OK: supply chain fail-closed, catch-up, edad, energía, reintentos y concurrencia validados."
