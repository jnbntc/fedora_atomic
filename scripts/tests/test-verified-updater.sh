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

if [[ "${1:-}" == refresh-md ]]; then
  [[ "${FAIL_REFRESH:-0}" != 1 ]] || exit 1
  if [[ -n "${MOVE_CLOCK_AT_REFRESH:-}" ]]; then
    printf '%s\n' "$MOVE_CLOCK_AT_REFRESH" >"$FAKE_CLOCK"
  fi
  if [[ "${CHANGE_DEPLOYMENTS_AT_REFRESH:-0}" == 1 ]]; then
    jq '.deployments[0].checksum = "admin-change"' "$FAKE_STATE" >"${FAKE_STATE}.tmp"
    mv "${FAKE_STATE}.tmp" "$FAKE_STATE"
  fi
  exit 0
fi

if [[ "${1:-}" == rebase || "${1:-}" == upgrade ]]; then
  operation="$1"
  [[ "${FAIL_REBASE:-0}" != 1 && "${FAIL_SOLVE:-0}" != 1 ]] || exit 1
  if [[ "$operation" == upgrade ]]; then
    [[ "${FAIL_UPGRADE:-0}" != 1 ]] || exit 1
    [[ "${UPGRADE_UNCHANGED:-0}" != 1 ]] || exit 77
    target="$(jq -r '.deployments[0]["container-image-reference"]' "$FAKE_STATE")"
    shift 2 # upgrade --unchanged-exit-77
  else
    target="${2:?}"
    shift 2
  fi
  digest="${target##*@}"
  [[ "${WRONG_STAGE:-0}" != 1 ]] || digest="sha256:unexpected"
  installs=() uninstalls=()
  for option in "$@"; do
    case "$option" in
      --install=*) installs+=("${option#*=}") ;;
      --uninstall=*) uninstalls+=("${option#*=}") ;;
      *) exit 2 ;;
    esac
  done
  [[ "${IGNORE_MIGRATIONS:-0}" != 1 ]] || { installs=(); uninstalls=(); }
  install_json="$(jq -cn '$ARGS.positional' --args "${installs[@]}")"
  uninstall_json="$(jq -cn '$ARGS.positional' --args "${uninstalls[@]}")"
  jq --arg d "$digest" --arg r "$target" --argjson add "$install_json" --argjson remove "$uninstall_json" --arg failure "${POSTVALIDATION_FAILURE:-}" '
    .deployments[0] as $origin
    | .deployments = ([$origin | .booted=false | .staged=true
      | .["container-image-reference"]=$r | .["container-image-reference-digest"]=$d
      | .["requested-local-packages"] = [(. // {})["requested-local-packages"][]? | . as $p | select($remove | index($p) | not)]
      | .["requested-packages"] = (((.["requested-packages"] // []) + $add) | unique)]
      + [.deployments[] | select(.booted == true)])
    | .deployments[0] |= (
      if $failure == "mutable-reference" then .["container-image-reference"] = "ostree-unverified-registry:ghcr.io/test/fedora_atomic:stable"
      elif $failure == "missing-migrated" then .["requested-packages"] -= ["chatgpt"]
      elif $failure == "retained-local" then .["requested-local-packages"] += [$origin["requested-local-packages"][0]]
      elif $failure == "lost-local" then .["requested-local-packages"] = []
      elif $failure == "lost-layered" then .["requested-packages"] -= ["custom-layer"]
      elif $failure == "not-pending" then .booted = true
      else . end)
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
export FEDORA_ATOMIC_HOST_PACKAGES_CONFIG="${ROOT_DIR}/files/etc/fedora-atomic/host-packages.json"

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

# Caso 3: staged gestionado viejo -> reemplazo transaccional sin cleanup.
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

if grep -Fq 'rpm-ostree cleanup --pending' "$LOG"; then
  echo 'FAIL: eliminó pendiente antes de completar la transacción' >&2
  exit 1
fi
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
  unset FAIL_REFRESH MOVE_CLOCK_AT_REFRESH CHANGE_DEPLOYMENTS_AT_REFRESH FAIL_SOLVE FAIL_UPGRADE UPGRADE_UNCHANGED IGNORE_MIGRATIONS
  unset JQ_BIN POSTVALIDATION_FAILURE
  export FEDORA_ATOMIC_HOST_PACKAGES_CONFIG="${ROOT_DIR}/files/etc/fedora-atomic/host-packages.json"
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
  if grep -Eq '^rpm-ostree (rebase|upgrade|cleanup)' "$LOG"; then
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
  jq --arg d "$DIGEST" --arg f "$field" --arg r "ostree-unverified-registry:$REPO@$DIGEST" \
    '.deployments[0] |= (.booted=false | .[$f]=true | .["container-image-reference-digest"]=$d | .["container-image-reference"]=$r)' \
    "$STATE" >"${STATE}.tmp"
  mv "${STATE}.tmp" "$STATE"
  if [[ "$field" == staged ]]; then
    jq '.deployments += [{booted:true,staged:false}]' "$STATE" >"${STATE}.tmp"
    mv "${STATE}.tmp" "$STATE"
  fi
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

# Paquetes host-locales: fixtures de solicitudes, sin instalar RPM reales.
CHATGPT_LOCAL=chatgpt-26.928.20755-1.x86_64
TEAMVIEWER_LOCAL=teamviewer-15.80.4-0.x86_64
OTHER_LOCAL=chatgpt-addon-1.0-1.x86_64

with_local_apps() {
  jq --arg c "$CHATGPT_LOCAL" --arg t "$TEAMVIEWER_LOCAL" --arg o "$OTHER_LOCAL" '
    .deployments[0]["requested-local-packages"] = [$c,$t,$o]
    | .deployments[0]["requested-packages"] = ["custom-layer"]
  ' "$STATE" >"${STATE}.tmp"
  mv "${STATE}.tmp" "$STATE"
}

same_base() {
  jq --arg d "$DIGEST" --arg r "ostree-unverified-registry:$REPO@$DIGEST" '
    .deployments[0]["container-image-reference-digest"]=$d
    | .deployments[0]["container-image-reference"]=$r
  ' "$STATE" >"${STATE}.tmp"
  mv "${STATE}.tmp" "$STATE"
}

assert_migrated() {
  jq -e --arg other "$OTHER_LOCAL" '
    .deployments[0] as $d
    | ($d["requested-packages"] | index("chatgpt")) != null
      and ($d["requested-packages"] | index("teamviewer")) != null
      and ($d["requested-packages"] | index("custom-layer")) != null
      and $d["requested-local-packages"] == [$other]
  ' "$STATE" >/dev/null
  if grep -Eq 'rpm-ostree (cleanup|uninstall|install) ' "$LOG"; then
    echo 'FAIL: migración separada/no transaccional' >&2
    exit 1
  fi
}

expect_failure_without_success() {
  if bash "$SCRIPT" >"${TMP_DIR}/output" 2>&1; then
    echo 'FAIL: se ignoró un error de la actualización host-local' >&2
    cat "${TMP_DIR}/output" >&2
    exit 1
  fi
  [[ ! -f "${FEDORA_ATOMIC_STATE_DIR}/last-success" ]]
}

# Nuevo digest + migración atómica, preservando otros locales y capas.
reset_policy '2026-10-14 20:00:00'
with_local_apps
expect_staged
grep -Fq "rpm-ostree rebase ostree-unverified-registry:$REPO@$DIGEST --uninstall=$CHATGPT_LOCAL --install=chatgpt --uninstall=$TEAMVIEWER_LOCAL --install=teamviewer" "$LOG"
assert_migrated

# Pendiente de otra imagen gestionada: derivar de sus solicitudes, no del booted.
reset_policy '2026-10-14 20:00:00'
with_local_apps
jq '.deployments = ([.deployments[0] | .booted=false | .staged=false]
  + [.deployments[0] | .["requested-local-packages"]=[] | .["requested-packages"]=["booted-only"]])' "$STATE" >"${STATE}.tmp"
mv "${STATE}.tmp" "$STATE"
expect_staged
assert_migrated

# Mismo digest: upgrade sobre el origen inmutable, sin rebase al mismo ref.
reset_policy '2026-10-14 20:00:00'
with_local_apps
same_base
bash "$SCRIPT" >/dev/null
assert_migrated
grep -Fq 'rpm-ostree refresh-md --force' "$LOG"
grep -Fq "rpm-ostree upgrade --unchanged-exit-77 --uninstall=$CHATGPT_LOCAL --install=chatgpt" "$LOG"
if grep -Fq 'rpm-ostree rebase ' "$LOG"; then exit 1; fi

# Simular reboot de la migración: siguientes comprobaciones no la repiten.
jq '.deployments = [.deployments[0] | .booted=true | .staged=false]' "$STATE" >"${STATE}.tmp"
mv "${STATE}.tmp" "$STATE"
printf '2026-10-15 02:30:00\n' >"$FAKE_CLOCK"
: >"$LOG"
export UPGRADE_UNCHANGED=1
bash "$SCRIPT" >"${TMP_DIR}/output"
grep -Fq 'Stable y paquetes de repositorio sin novedades.' "${TMP_DIR}/output"
if grep -Fq -- '--uninstall=' "$LOG"; then exit 1; fi
[[ "$(cat "${FEDORA_ATOMIC_STATE_DIR}/last-success")" == "$(date +%s)" ]]

# Capas gestionadas ya migradas: se actualizan aun sin nueva base.
reset_policy '2026-10-14 20:00:00'
same_base
jq '.deployments[0]["requested-packages"] = ["chatgpt"]' "$STATE" >"${STATE}.tmp"
mv "${STATE}.tmp" "$STATE"
bash "$SCRIPT" >/dev/null
grep -Fxq 'rpm-ostree upgrade --unchanged-exit-77' "$LOG"
[[ "$(cat "${FEDORA_ATOMIC_STATE_DIR}/last-success")" == "$(date +%s)" ]]

# Aplicación ausente o RPM local fuera de la lista: nunca instalar/migrar.
reset_policy '2026-10-14 20:00:00'
same_base
jq --arg o "$OTHER_LOCAL" '.deployments[0]["requested-local-packages"] = [$o]' "$STATE" >"${STATE}.tmp"
mv "${STATE}.tmp" "$STATE"
bash "$SCRIPT" >/dev/null
expect_no_stage
if grep -Fq 'rpm-ostree refresh-md' "$LOG"; then exit 1; fi

# Opt-out explícito y validación estricta de política.
reset_policy '2026-10-14 20:00:00'
with_local_apps
same_base
export FEDORA_ATOMIC_HOST_PACKAGES_CONFIG="${TMP_DIR}/policy.json"
printf '{"schema_version":1,"packages":[]}\n' >"$FEDORA_ATOMIC_HOST_PACKAGES_CONFIG"
bash "$SCRIPT" >/dev/null
expect_no_stage
printf '2026-10-15 02:30:00\n' >"$FAKE_CLOCK"
for policy in '{"schema_version":2,"packages":[]}' \
              '{"schema_version":1,"packages":["chatgpt","chatgpt"]}' \
              '{"schema_version":1,"packages":["--reboot"]}' \
              '{"schema_version":1,"packages":[1]}' '{malformed'; do
  : >"$LOG"
  rm -f "${FEDORA_ATOMIC_STATE_DIR}/last-success"
  printf '%s\n' "$policy" >"$FEDORA_ATOMIC_HOST_PACKAGES_CONFIG"
  expect_failure_without_success
  expect_no_stage
done
rm "$FEDORA_ATOMIC_HOST_PACKAGES_CONFIG"
expect_failure_without_success

# Fallo de metadatos, repos/firmas/dependencias o upgrade: nunca perder el pendiente.
for failure in FAIL_REFRESH FAIL_SOLVE; do
  reset_policy '2026-10-14 20:00:00'
  with_local_apps
  jq '.deployments = ([.deployments[0] | .booted=false | .staged=true] + .deployments)' "$STATE" >"${STATE}.tmp"
  mv "${STATE}.tmp" "$STATE"
  cp "$STATE" "${STATE}.before"
  export "$failure=1"
  expect_failure_without_success
  cmp "$STATE" "${STATE}.before"
  if grep -Fq 'rpm-ostree cleanup' "$LOG"; then exit 1; fi
done
for failure in FAIL_UPGRADE WRONG_STAGE IGNORE_MIGRATIONS UPGRADE_UNCHANGED; do
  reset_policy '2026-10-14 20:00:00'
  with_local_apps
  same_base
  export "$failure=1"
  expect_failure_without_success
done

# No hacer upgrade desde un tag mutable ni sobre un pendiente ajeno.
reset_policy '2026-10-14 20:00:00'
with_local_apps
same_base
jq --arg r "ostree-unverified-registry:$REPO:stable" '.deployments[0]["container-image-reference"]=$r' "$STATE" >"${STATE}.tmp"
mv "${STATE}.tmp" "$STATE"
expect_failure_without_success
expect_no_stage
reset_policy '2026-10-14 20:00:00'
with_local_apps
same_base
jq '.deployments = ([.deployments[0] | .booted=false | .staged=false
  | .["container-image-reference"]="ostree-unverified-registry:ghcr.io/foreign/image@sha256:bad"] + .deployments)' "$STATE" >"${STATE}.tmp"
mv "${STATE}.tmp" "$STATE"
expect_failure_without_success
expect_no_stage

# Pendiente correcto sin staged=true: conservarlo, incluso con apps locales.
reset_policy '2026-10-14 20:00:00'
with_local_apps
same_base
jq '.deployments = ([.deployments[0] | .booted=false | .staged=false] + .deployments)' "$STATE" >"${STATE}.tmp"
mv "${STATE}.tmp" "$STATE"
bash "$SCRIPT" >/dev/null
expect_no_stage

# Cambio de guarda o deployments durante refresh-md: no comenzar transacción.
reset_policy '2026-10-14 07:59:00'
with_local_apps
export MOVE_CLOCK_AT_REFRESH='2026-10-14 08:00:00'
bash "$SCRIPT" >"${TMP_DIR}/output"
expect_no_stage
[[ ! -f "${FEDORA_ATOMIC_STATE_DIR}/last-success" ]]
reset_policy '2026-10-14 20:00:00'
with_local_apps
export CHANGE_DEPLOYMENTS_AT_REFRESH=1
expect_failure_without_success
expect_no_stage

# La presencia de paquetes gestionados no salta horario ni verificación OCI.
reset_policy '2026-10-14 12:00:00'
with_local_apps
expect_deferred
reset_policy '2026-10-14 20:00:00'
with_local_apps
export FAIL_COSIGN=1
expect_failure_without_success
expect_no_stage
if grep -Fq 'rpm-ostree refresh-md' "$LOG"; then exit 1; fi

# Regresión ARG_MAX: rechazar payloads JSON en argv independientemente del SO.
# Sólo el updater usa este wrapper; los fixtures siguen usando el jq real.
REAL_JQ="$(command -v jq)"
export REAL_JQ
cat >"${BIN}/jq-stdin-guard" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
for argument in "$@"; do
  case "$argument" in
    *updater-status-sentinel*|*updater-request-sentinel*)
      echo 'FAIL: JSON de estado/solicitudes pasado por argv a jq' >&2
      exit 99 ;;
  esac
done
exec "${REAL_JQ:?}" "$@"
EOF
chmod +x "${BIN}/jq-stdin-guard"

for scenario in small-marker large-rebase large-same-base large-requests; do
  reset_policy '2026-10-14 20:00:00'
  with_local_apps
  [[ "$scenario" != large-same-base ]] || same_base
  # El primer caso reproduce el error por contrato, sin depender de ARG_MAX.
  # Los restantes incluyen >2 MiB de metadata irrelevante en deployments.
  padding=2097152
  [[ "$scenario" != small-marker ]] || padding=512
  jq --argjson padding "$padding" '
    .deployments[0].metadata = {irrelevant: ("updater-status-sentinel:" + ("x" * $padding))}
  ' "$STATE" >"${STATE}.tmp"
  mv "${STATE}.tmp" "$STATE"
  if [[ "$scenario" == large-requests ]]; then
    # También las estructuras mínimas pueden superar el límite por argumento.
    jq '
      .deployments[0]["requested-local-packages"] += [range(600)
        | "updater-request-sentinel-local-" + ("x" * 240) + (tostring) + "-1.0-1.x86_64"]
      | .deployments[0]["requested-packages"] += [range(600)
        | "updater-request-sentinel-layer-" + ("x" * 240) + (tostring)]
    ' "$STATE" >"${STATE}.tmp"
    mv "${STATE}.tmp" "$STATE"
  fi
  export JQ_BIN="${BIN}/jq-stdin-guard"
  if ! bash "$SCRIPT" >"${TMP_DIR}/output" 2>&1; then
    echo "FAIL: falso negativo con JSON de estado: $scenario" >&2
    cat "${TMP_DIR}/output" >&2
    exit 1
  fi
  [[ "$(cat "${FEDORA_ATOMIC_STATE_DIR}/last-success")" == "$(date +%s)" ]]
  grep -Fq 'Update preparado correctamente.' "${TMP_DIR}/output"
  if grep -Eq 'ERROR:|Argument list too long' "${TMP_DIR}/output"; then exit 1; fi
  if [[ "$scenario" == large-same-base ]]; then
    grep -Fq 'rpm-ostree upgrade --unchanged-exit-77' "$LOG"
  else
    grep -Fq "rpm-ostree rebase ostree-unverified-registry:$REPO@$DIGEST" "$LOG"
  fi
  if [[ "$scenario" == large-requests ]]; then
    jq -e '.deployments[0] | (.["requested-local-packages"] | length) == 601
      and (.["requested-packages"] | length) == 603' "$STATE" >/dev/null
  else
    assert_migrated
  fi
done

# La nueva forma de transportar JSON no debe relajar ninguna postcondición.
# WRONG_STAGE ya cubre el digest incorrecto; aquí cubrimos los otros invariantes.
for failure in mutable-reference missing-migrated retained-local lost-local lost-layered not-pending; do
  reset_policy '2026-10-14 20:00:00'
  with_local_apps
  export POSTVALIDATION_FAILURE="$failure"
  expect_failure_without_success
  grep -Fq 'rpm-ostree no dejó el digest y las solicitudes de paquetes esperados' "${TMP_DIR}/output"
done

echo "OK: supply chain, catch-up, migración y actualizaciones RPM con base estable validadas."
