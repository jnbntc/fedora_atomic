#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
export POWER_SUPPLY_ROOT="$TMP_DIR/supplies"
export TUNED_ADM="$TMP_DIR/tuned-adm"
export FAKE_LOG="$TMP_DIR/calls"
export FAKE_ACTIVE=powersave
cat >"$TUNED_ADM" <<'FAKE'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"${FAKE_LOG:?}"
case "$1" in
  active)
    [[ "${FAKE_ACTIVE:-}" != error ]] || exit 1
    printf 'Current active profile: %s\n' "${FAKE_ACTIVE:-none}"
    ;;
  profile) ;;
  *) exit 1 ;;
esac
FAKE
chmod 0755 "$TUNED_ADM"
reset_supplies() {
  rm -rf "$POWER_SUPPLY_ROOT"
  mkdir -p "$POWER_SUPPLY_ROOT"
  : >"$FAKE_LOG"
  export FAKE_ACTIVE=none
}
supply() {
  mkdir -p "$POWER_SUPPLY_ROOT/$1"
  printf '%s\n' "$2" >"$POWER_SUPPLY_ROOT/$1/type"
  if [[ "$3" != missing ]]; then
    printf '%s\n' "$3" >"$POWER_SUPPLY_ROOT/$1/online"
  fi
}
run_profile() {
  bash "$ROOT_DIR/files/usr/libexec/fedora-power-profile" >"$TMP_DIR/output" 2>&1
}
expect_profile() {
  run_profile
  grep -Fxq "profile $1" "$FAKE_LOG"
  [[ "$(grep -c '^profile ' "$FAKE_LOG")" == 1 ]]
  grep -Fq "Perfil seleccionado: $1" "$TMP_DIR/output"
}
expect_unknown() {
  run_profile
  [[ ! -s "$FAKE_LOG" ]]
  grep -Fq '[WARNING]' "$TMP_DIR/output"
}
reset_supplies; supply AC Mains 1; expect_profile balanced
reset_supplies; supply AC Mains 0; expect_profile powersave
reset_supplies; supply USB0 USB_C 1; expect_profile balanced
reset_supplies; supply BAT0 Battery 1; expect_unknown
reset_supplies; supply BAT0 Battery 1; supply AC Mains 0; expect_profile powersave
reset_supplies; expect_unknown
reset_supplies; supply AC Mains missing; expect_unknown
reset_supplies; supply AC Mains invalid; expect_unknown
reset_supplies; supply AC Mains 0; mkdir -p "$POWER_SUPPLY_ROOT/unknown"; expect_unknown
reset_supplies; supply AC Mains 0; supply USB0 USB missing; expect_unknown
reset_supplies; supply AC Mains 0; supply USB0 USB 1; expect_profile balanced
reset_supplies; supply AC Mains 1; supply USB0 USB missing; expect_profile balanced
for profile in balanced powersave; do
  reset_supplies
  online=0
  [[ "$profile" != balanced ]] || online=1
  supply AC Mains "$online"
  export FAKE_ACTIVE="$profile"
  run_profile
  grep -Fxq active "$FAKE_LOG"
  if grep -q '^profile ' "$FAKE_LOG"; then
    echo 'FAIL: volvió a aplicar un perfil activo' >&2
    exit 1
  fi
done
reset_supplies; supply AC Mains 1; export FAKE_ACTIVE=error; expect_profile balanced
reset_supplies; supply AC Mains 1
TUNED_ADM="$TMP_DIR/absent" run_profile
[[ ! -s "$FAKE_LOG" ]]
grep -Fq '[WARNING]' "$TMP_DIR/output"
echo 'OK: perfiles de energía validados con fuentes y TuneD simulados.'
