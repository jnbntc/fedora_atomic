#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

BIN="${TMP_DIR}/bin"
LOG="${TMP_DIR}/calls.log"
EVIDENCE="${TMP_DIR}/evidence"
mkdir -p "$BIN"
: >"$LOG"

REVISION="0123456789abcdef0123456789abcdef01234567"
DIGEST="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
REPO="ghcr.io/test/fedora_atomic"

cat >"${BIN}/skopeo" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'skopeo %s\\n' "\$*" >>"$LOG"
cat <<'JSON'
{"Digest":"$DIGEST","Labels":{"org.opencontainers.image.revision":"$REVISION"}}
JSON
EOF

cat >"${BIN}/cosign" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'cosign %s\n' "$*" >>"${FAKE_LOG:?}"
printf '[{"critical":{"identity":{"docker-reference":"test"}}}]\n'
EOF

cat >"${BIN}/gh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'gh %s\n' "$*" >>"${FAKE_LOG:?}"
if [[ "${1:-}" == "auth" && "${2:-}" == "token" ]]; then
  printf 'fake-token\n'
  exit 0
fi
printf '[{"verificationResult":{"statement":{"predicateType":"ok"}}}]\n'
EOF

cat >"${BIN}/rpm-ostree" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'rpm-ostree %s\n' "$*" >>"${FAKE_LOG:?}"

if [[ "${1:-}" == "status" && "${2:-}" == "--json" ]]; then
  printf '{"deployments":[]}\n'
  exit 0
fi

if [[ "${1:-}" == "status" ]]; then
  if [[ -n "${FAKE_LAYERED:-}" ]]; then
    printf 'State: idle\nDeployments:\nLayeredPackages: teamviewer\n'
  else
    printf 'State: idle\nDeployments:\n'
  fi
  exit 0
fi

if [[ "${1:-}" == "rebase" ]]; then
  exit 0
fi

exit 0
EOF

cat >"${BIN}/sudo" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'sudo %s\n' "$*" >>"${FAKE_LOG:?}"
"$@"
EOF

chmod +x "${BIN}/skopeo" "${BIN}/cosign" "${BIN}/gh" "${BIN}/rpm-ostree" "${BIN}/sudo"
export PATH="${BIN}:${PATH}"
export FAKE_LOG="$LOG"
unset GH_TOKEN

# ---------------------------------------------------------------------------
# verify-stable resuelve digest, revision y verifica supply chain.
# ---------------------------------------------------------------------------
verify_output="$(
  bash "$ROOT_DIR/scripts/recovery/verify-stable.sh" \
    --repository "$REPO" \
    --source-repository test/fedora_atomic \
    --evidence-dir "$EVIDENCE"
)"

grep -Fq "STABLE_DIGEST=$DIGEST" <<<"$verify_output"
grep -Fq "STABLE_REVISION=$REVISION" <<<"$verify_output"
grep -Fq "RPM_OSTREE_TARGET=ostree-unverified-registry:$REPO@$DIGEST" <<<"$verify_output"

jq -e --arg d "$DIGEST" --arg r "$REVISION" '
  .digest == $d
  and .source_revision == $r
  and .verification.cosign == true
  and .verification.slsa_provenance == true
  and .verification.spdx_attestation == true
' "$EVIDENCE/stable-resolution.json" >/dev/null

# ---------------------------------------------------------------------------
# rebase default es dry-run y no ejecuta sudo/rpm-ostree rebase.
# ---------------------------------------------------------------------------
: >"$LOG"
bash "$ROOT_DIR/scripts/recovery/rebase-stable.sh" \
  --repository "$REPO" \
  --source-repository test/fedora_atomic \
  --evidence-dir "${TMP_DIR}/dry" >/dev/null

if grep -Eq '^sudo |^rpm-ostree rebase ' "$LOG"; then
  echo "FAIL: dry-run modificó el host" >&2
  cat "$LOG" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# apply usa exactamente el digest verificado.
# ---------------------------------------------------------------------------
: >"$LOG"
bash "$ROOT_DIR/scripts/recovery/rebase-stable.sh" \
  --repository "$REPO" \
  --source-repository test/fedora_atomic \
  --evidence-dir "${TMP_DIR}/apply" \
  --apply >/dev/null

grep -Fq "rpm-ostree rebase ostree-unverified-registry:$REPO@$DIGEST" "$LOG" || {
  echo "FAIL: apply no fijó el rebase al digest verificado" >&2
  cat "$LOG" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# layered state bloquea apply salvo consentimiento explícito.
# ---------------------------------------------------------------------------
: >"$LOG"
export FAKE_LAYERED=1

if bash "$ROOT_DIR/scripts/recovery/rebase-stable.sh" \
  --repository "$REPO" \
  --source-repository test/fedora_atomic \
  --evidence-dir "${TMP_DIR}/layered" \
  --apply >/dev/null 2>&1; then
  echo "FAIL: apply aceptó layered state sin --allow-layered" >&2
  exit 1
fi

if grep -Fq 'rpm-ostree rebase ' "$LOG"; then
  echo "FAIL: layered state alcanzó rebase sin autorización" >&2
  exit 1
fi
unset FAKE_LAYERED

# ---------------------------------------------------------------------------
# Contrato estático del recovery drill y documentación.
# ---------------------------------------------------------------------------
workflow="$ROOT_DIR/.github/workflows/recovery-drill.yml"

grep -Fq "cron: '43 09 1 * *'" "$workflow" || {
  echo "FAIL: recovery drill no tiene schedule mensual esperado" >&2
  exit 1
}

grep -Fq 'workflow_dispatch:' "$workflow" || {
  echo "FAIL: recovery drill no admite ejecución manual" >&2
  exit 1
}

if grep -Fq 'packages: write' "$workflow" || grep -Fq 'id-token: write' "$workflow"; then
  echo "FAIL: recovery drill tiene permisos de escritura innecesarios" >&2
  exit 1
fi

grep -Fq 'packages: read' "$workflow"
grep -Fq 'attestations: read' "$workflow"
grep -Fq 'scripts/recovery/verify-stable.sh' "$workflow"
grep -Fq 'steps.stable.outputs.digest' "$workflow"
grep -Fq 'scripts/smoke/test-image.sh' "$workflow"
grep -Fq 'evaluate-fedora-advisories.sh' "$workflow"
grep -Fq 'retention-days: 90' "$workflow"

for doc in docs/OPERATIONS.md docs/HOST-SETUP.md docs/DISASTER-RECOVERY.md; do
  [[ -s "$ROOT_DIR/$doc" ]] || {
    echo "FAIL: falta documento $doc" >&2
    exit 1
  }
done

grep -Fq 'scripts/recovery/verify-stable.sh' "$ROOT_DIR/docs/DISASTER-RECOVERY.md"
grep -Fq 'rpm-ostree rollback' "$ROOT_DIR/docs/DISASTER-RECOVERY.md"
grep -Fq 'rpm-ostree cleanup --pending' "$ROOT_DIR/docs/DISASTER-RECOVERY.md"
grep -Fq 'stable' "$ROOT_DIR/docs/HOST-SETUP.md"

echo "OK: helpers, runbooks y recovery drill validados."


if [[ -e "$ROOT_DIR/.github/workflows/stage10-recovery-probe.yml" ]]; then
  echo "FAIL: quedó workflow temporal de Etapa 10" >&2
  exit 1
fi

echo "OK: no queda workflow temporal de recovery."

# Snapshot: diagnósticos separados y tolerancia a un user bus ausente.
cat >"${BIN}/systemctl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'systemctl %s\n' "$*" >>"${FAKE_LOG:?}"
if [[ "${1:-}" == --user ]]; then
  echo 'Failed to connect to user bus' >&2
  exit 1
fi
printf 'system diagnostic\n'
EOF
cat >"${BIN}/tuned-adm" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'tuned-adm %s\n' "$*" >>"${FAKE_LOG:?}"
printf 'Current active profile: balanced\n'
EOF
for name in rpm flatpak; do
  printf '#!/usr/bin/env bash\nexit 0\n' >"${BIN}/$name"
done
chmod +x "${BIN}/systemctl" "${BIN}/tuned-adm" "${BIN}/rpm" "${BIN}/flatpak"
bash "$ROOT_DIR/scripts/recovery/capture-host-state.sh" "${TMP_DIR}/snapshots" >/dev/null
snapshots=("${TMP_DIR}/snapshots"/*)
snapshot="${snapshots[0]}"
grep -Fxq 'systemctl --failed --no-pager' "$LOG"
grep -Fxq 'systemctl --user --failed --no-pager' "$LOG"
grep -Fxq 'tuned-adm active' "$LOG"
grep -Fq 'system diagnostic' "$snapshot/system-failed-units.txt"
grep -Fq 'Failed to connect to user bus' "$snapshot/user-failed-units.txt"
grep -Fq 'balanced' "$snapshot/tuned-active-profile.txt"
for filename in system-failed-units.txt user-failed-units.txt tuned-active-profile.txt; do
  grep -Fq "$filename" "$snapshot/README.txt"
done
echo "OK: snapshot separa system/user y tolera user bus ausente."
