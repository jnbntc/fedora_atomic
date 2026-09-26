#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="${ROOT_DIR}/scripts/cleanup-ghcr.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FAKE_BIN="${TMP_DIR}/bin"
FIXTURE="${TMP_DIR}/versions.json"
DELETE_LOG="${TMP_DIR}/deletes.log"
mkdir -p "$FAKE_BIN"
: >"$DELETE_LOG"

old_date="$(date -u -d '30 days ago' +'%Y-%m-%dT%H:%M:%SZ')"
recent_date="$(date -u -d '1 day ago' +'%Y-%m-%dT%H:%M:%SZ')"

cat >"$FIXTURE" <<EOF
[
  {"id":100,"updated_at":"$old_date","metadata":{"container":{"tags":["latest"]}}},
  {"id":99,"updated_at":"$recent_date","metadata":{"container":{"tags":["20260925"]}}},
  {"id":98,"updated_at":"$old_date","metadata":{"container":{"tags":["old-1"]}}},
  {"id":97,"updated_at":"$old_date","metadata":{"container":{"tags":["old-2"]}}},
  {"id":96,"updated_at":"$old_date","metadata":{"container":{"tags":["old-3"]}}},
  {"id":95,"updated_at":"$old_date","metadata":{"container":{"tags":["old-4"]}}},
  {"id":94,"updated_at":"$old_date","metadata":{"container":{"tags":["old-5"]}}},
  {"id":93,"updated_at":"$old_date","metadata":{"container":{"tags":["old-6"]}}},
  {"id":92,"updated_at":"$old_date","metadata":{"container":{"tags":[]}}}
]
EOF

cat >"${FAKE_BIN}/gh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

if [[ " $* " == *" --method DELETE "* ]]; then
  printf '%s\n' "$*" >>"${GH_FAKE_DELETE_LOG:?}"
  exit 0
fi

cat "${GH_FAKE_FIXTURE:?}"
EOF
chmod +x "${FAKE_BIN}/gh"

export PATH="${FAKE_BIN}:${PATH}"
export GH_TOKEN="test-token"
export GH_FAKE_FIXTURE="$FIXTURE"
export GH_FAKE_DELETE_LOG="$DELETE_LOG"

dry_output="$(
  "$SCRIPT"     --dry-run     --owner test-user     --retention-days 14     --keep-old-tagged 5     --package fedora_atomic
)"

[[ ! -s "$DELETE_LOG" ]] || {
  echo "FAIL: dry-run ejecutó DELETE" >&2
  exit 1
}

grep -q 'version=92' <<<"$dry_output" || {
  echo "FAIL: dry-run no seleccionó untagged id=92" >&2
  exit 1
}

grep -q 'version=93' <<<"$dry_output" || {
  echo "FAIL: dry-run no seleccionó build antiguo id=93" >&2
  exit 1
}

: >"$DELETE_LOG"

"$SCRIPT"   --apply   --owner test-user   --retention-days 14   --keep-old-tagged 5   --package fedora_atomic >/dev/null

[[ "$(wc -l <"$DELETE_LOG")" -eq 2 ]] || {
  echo "FAIL: se esperaban exactamente 2 DELETE" >&2
  cat "$DELETE_LOG" >&2
  exit 1
}

grep -q '/versions/92' "$DELETE_LOG" || {
  echo "FAIL: falta DELETE de untagged id=92" >&2
  exit 1
}

grep -q '/versions/93' "$DELETE_LOG" || {
  echo "FAIL: falta DELETE del build antiguo id=93" >&2
  exit 1
}

if grep -q '/versions/100' "$DELETE_LOG"; then
  echo "FAIL: intentó borrar latest id=100" >&2
  exit 1
fi

echo "OK: cleanup-ghcr.sh pasó las pruebas de dry-run y retención."
