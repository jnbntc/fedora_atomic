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

recent_1="$(date -u -d '1 day ago' +'%Y-%m-%dT%H:%M:%SZ')"
recent_2="$(date -u -d '2 days ago' +'%Y-%m-%dT%H:%M:%SZ')"
old_1="$(date -u -d '20 days ago' +'%Y-%m-%dT%H:%M:%SZ')"
old_2="$(date -u -d '21 days ago' +'%Y-%m-%dT%H:%M:%SZ')"
old_3="$(date -u -d '22 days ago' +'%Y-%m-%dT%H:%M:%SZ')"
old_4="$(date -u -d '23 days ago' +'%Y-%m-%dT%H:%M:%SZ')"
old_5="$(date -u -d '24 days ago' +'%Y-%m-%dT%H:%M:%SZ')"
old_6="$(date -u -d '25 days ago' +'%Y-%m-%dT%H:%M:%SZ')"

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
export GH_FAKE_DELETE_LOG="$DELETE_LOG"

# ---------------------------------------------------------------------------
# Política de la imagen principal:
# - latest siempre protegido
# - solo tags gestionados pueden purgarse
# - cualquier tag especial protege la versión
# ---------------------------------------------------------------------------
cat >"$FIXTURE" <<EOF
[
  {"id":100,"updated_at":"$old_6","metadata":{"container":{"tags":["latest","sha-1111111111111111111111111111111111111111","20260901-111111111111","run-100-1"]}}},
  {"id":99,"updated_at":"$recent_1","metadata":{"container":{"tags":["sha-2222222222222222222222222222222222222222","20260926-222222222222","run-99-1"]}}},
  {"id":98,"updated_at":"$old_1","metadata":{"container":{"tags":["sha-3333333333333333333333333333333333333333","20260830-333333333333","run-98-1"]}}},
  {"id":97,"updated_at":"$old_2","metadata":{"container":{"tags":["sha-4444444444444444444444444444444444444444","20260829-444444444444","run-97-1"]}}},
  {"id":96,"updated_at":"$old_3","metadata":{"container":{"tags":["sha-5555555555555555555555555555555555555555","20260828-555555555555","run-96-1"]}}},
  {"id":95,"updated_at":"$old_4","metadata":{"container":{"tags":["sha-6666666666666666666666666666666666666666","20260827-666666666666","run-95-1"]}}},
  {"id":94,"updated_at":"$old_5","metadata":{"container":{"tags":["sha-7777777777777777777777777777777777777777","20260826-777777777777","run-94-1"]}}},
  {"id":93,"updated_at":"$old_6","metadata":{"container":{"tags":["20260801"]}}},
  {"id":91,"updated_at":"$old_6","metadata":{"container":{"tags":["stable","sha-8888888888888888888888888888888888888888"]}}},
  {"id":90,"updated_at":"$old_6","metadata":{"container":{"tags":["candidate"]}}},
  {"id":92,"updated_at":"$old_6","metadata":{"container":{"tags":[]}}}
]
EOF
export GH_FAKE_FIXTURE="$FIXTURE"

dry_output="$(
  bash "$SCRIPT" \
    --dry-run \
    --owner test-user \
    --retention-days 14 \
    --keep-old-tagged 5 \
    --package fedora_atomic
)"

[[ ! -s "$DELETE_LOG" ]] || {
  echo "FAIL: dry-run de imagen principal ejecutó DELETE" >&2
  exit 1
}

grep -q 'version=92' <<<"$dry_output" || {
  echo "FAIL: no seleccionó untagged id=92" >&2
  exit 1
}

grep -q 'version=93' <<<"$dry_output" || {
  echo "FAIL: no seleccionó build gestionado antiguo id=93" >&2
  exit 1
}

for protected in 100 91 90; do
  if grep -q "version=$protected" <<<"$dry_output"; then
    echo "FAIL: intentó borrar versión protegida id=$protected" >&2
    exit 1
  fi
done

: >"$DELETE_LOG"

bash "$SCRIPT" \
  --apply \
  --owner test-user \
  --retention-days 14 \
  --keep-old-tagged 5 \
  --package fedora_atomic >/dev/null

[[ "$(wc -l <"$DELETE_LOG")" -eq 2 ]] || {
  echo "FAIL: imagen principal esperaba exactamente 2 DELETE" >&2
  cat "$DELETE_LOG" >&2
  exit 1
}

grep -q '/versions/92' "$DELETE_LOG"
grep -q '/versions/93' "$DELETE_LOG"
# ---------------------------------------------------------------------------
# Política del cache: conserva recientes y al menos N versiones etiquetadas
# ---------------------------------------------------------------------------
cat >"$FIXTURE" <<EOF
[
  {"id":210,"updated_at":"$recent_1","metadata":{"container":{"tags":["cache-a"]}}},
  {"id":209,"updated_at":"$recent_2","metadata":{"container":{"tags":["cache-b"]}}},
  {"id":208,"updated_at":"$old_1","metadata":{"container":{"tags":["cache-c"]}}},
  {"id":207,"updated_at":"$old_2","metadata":{"container":{"tags":["cache-d"]}}},
  {"id":206,"updated_at":"$old_3","metadata":{"container":{"tags":["cache-e"]}}},
  {"id":205,"updated_at":"$old_4","metadata":{"container":{"tags":["cache-f"]}}},
  {"id":204,"updated_at":"$old_5","metadata":{"container":{"tags":[]}}}
]
EOF

: >"$DELETE_LOG"

cache_dry="$(
  bash "$SCRIPT"     --dry-run     --owner test-user     --cache-retention-days 14     --cache-keep-min 3     --package 'fedora_atomic%2Fcache'
)"

[[ ! -s "$DELETE_LOG" ]] || {
  echo "FAIL: dry-run de cache ejecutó DELETE" >&2
  exit 1
}

for id in 204 205 206 207; do
  grep -q "version=${id}" <<<"$cache_dry" || {
    echo "FAIL: cache no seleccionó id=${id}" >&2
    exit 1
  }
done

for id in 208 209 210; do
  if grep -q "version=${id}" <<<"$cache_dry"; then
    echo "FAIL: cache intentó borrar versión protegida id=${id}" >&2
    exit 1
  fi
done

: >"$DELETE_LOG"

bash "$SCRIPT"   --apply   --owner test-user   --cache-retention-days 14   --cache-keep-min 3   --package 'fedora_atomic%2Fcache' >/dev/null

[[ "$(wc -l <"$DELETE_LOG")" -eq 4 ]] || {
  echo "FAIL: cache esperaba exactamente 4 DELETE" >&2
  cat "$DELETE_LOG" >&2
  exit 1
}

for id in 204 205 206 207; do
  grep -q "/versions/${id}" "$DELETE_LOG"
done

echo "OK: cleanup-ghcr.sh pasó pruebas de imagen principal y cache."
