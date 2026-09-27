#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="${ROOT_DIR}/scripts/publish/publish-channels.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

BIN="${TMP_DIR}/bin"
MAP="${TMP_DIR}/map.tsv"
LOG="${TMP_DIR}/calls.log"
mkdir -p "$BIN"
: >"$LOG"

REV="0123456789abcdef0123456789abcdef01234567"
DIGEST="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
OTHER="sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
REPO="ghcr.io/test/fedora_atomic"

cat >"${BIN}/skopeo" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'skopeo %s\n' "$*" >>"${FAKE_LOG:?}"

if [[ "${1:-}" == "inspect" ]]; then
  tag="${*: -1}"
  tag="${tag##*:}"
  awk -F'|' -v tag="$tag" '$1 == tag {print $2; found=1; exit} END{if(!found) exit 1}' "${FAKE_MAP:?}"
  exit
fi

if [[ "${1:-}" == "copy" ]]; then
  src="${2:?}"
  dst="${3:?}"
  src_tag="${src##*:}"
  dst_tag="${dst##*:}"
  digest="$(awk -F'|' -v tag="$src_tag" '$1 == tag {print $2; exit}' "${FAKE_MAP:?}")"
  [[ -n "$digest" ]] || exit 2
  tmp="${FAKE_MAP}.tmp"
  awk -F'|' -v tag="$dst_tag" '$1 != tag {print}' "${FAKE_MAP}" >"$tmp"
  printf '%s|%s\n' "$dst_tag" "$digest" >>"$tmp"
  mv "$tmp" "${FAKE_MAP}"
  exit 0
fi

exit 2
EOF
chmod +x "${BIN}/skopeo"
export PATH="${BIN}:${PATH}"
export FAKE_LOG="$LOG"
export FAKE_MAP="$MAP"

printf 'sha-%s|%s\n' "$REV" "$DIGEST" >"$MAP"

bash "$SCRIPT" \
  --repository "$REPO" \
  --revision "$REV" \
  --digest "$DIGEST" \
  --evidence-file "${TMP_DIR}/channels.json" >/dev/null

grep -Fq 'skopeo copy' "$LOG"
grep -Fq ":candidate" "$LOG"
grep -Fq ":latest" "$LOG"
jq -e --arg d "$DIGEST" '.channels.candidate == $d and .channels.latest == $d' "${TMP_DIR}/channels.json" >/dev/null

printf 'sha-%s|%s\n' "$REV" "$OTHER" >"$MAP"
: >"$LOG"

if bash "$SCRIPT" --repository "$REPO" --revision "$REV" --digest "$DIGEST" >/dev/null 2>&1; then
  echo "FAIL: aceptó revision tag con digest distinto" >&2
  exit 1
fi

if grep -Fq 'skopeo copy' "$LOG"; then
  echo "FAIL: movió canales con digest conflictivo" >&2
  exit 1
fi

echo "OK: publicación de candidate/latest por digest validada."
