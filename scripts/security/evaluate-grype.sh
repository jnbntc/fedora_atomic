#!/usr/bin/env bash
set -Eeuo pipefail

REPORT="${1:-grype-rootfs-report.json}"
POLICY="${2:-security/vulnerability-policy.json}"

die() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 2
}

command -v jq >/dev/null 2>&1 || die "jq no está disponible"
[[ -f "$REPORT" ]] || die "No existe el reporte Grype: $REPORT"
[[ -f "$POLICY" ]] || die "No existe la política: $POLICY"

jq -e . "$REPORT" >/dev/null || die "Reporte Grype JSON inválido"
jq -e . "$POLICY" >/dev/null || die "Política JSON inválida"

expected_name="$(jq -r '.expected_distro.name' "$POLICY")"
expected_version="$(jq -r '.expected_distro.version' "$POLICY")"
actual_name="$(jq -r '.distro.name // empty' "$REPORT")"
actual_version="$(jq -r '.distro.version // empty' "$REPORT")"

[[ "$actual_name" == "$expected_name" ]] ||   die "Distro inesperada en Grype: '${actual_name:-<vacía>}' (esperada: $expected_name)"
[[ "$actual_version" == "$expected_version" ]] ||   die "Versión de distro inesperada: '${actual_version:-<vacía>}' (esperada: $expected_version)"

artifact_type="$(jq -r '.scope.artifact_type' "$POLICY")"
namespace_prefix="$(jq -r '.scope.namespace_prefix' "$POLICY")"
fix_state="$(jq -r '.block.fix_state' "$POLICY")"
block_severities="$(jq -c '.block.severities' "$POLICY")"
advisory_severities="$(jq -c '.advisory.severities' "$POLICY")"

count_matches() {
  local severities="$1"

  jq     --arg artifact_type "$artifact_type"     --arg namespace_prefix "$namespace_prefix"     --arg fix_state "$fix_state"     --argjson severities "$severities"     '[
      .matches[]?
      | select(.artifact.type == $artifact_type)
      | select((.vulnerability.namespace // "") | startswith($namespace_prefix))
      | select(.vulnerability.fix.state == $fix_state)
      | select((.vulnerability.fix.versions // []) | length > 0)
      | select(.vulnerability.severity as $sev | $severities | index($sev))
    ] | length' "$REPORT"
}

scope_matches="$(
  jq     --arg artifact_type "$artifact_type"     --arg namespace_prefix "$namespace_prefix"     '[
      .matches[]?
      | select(.artifact.type == $artifact_type)
      | select((.vulnerability.namespace // "") | startswith($namespace_prefix))
    ] | length' "$REPORT"
)"

blocked="$(count_matches "$block_severities")"
advisory="$(count_matches "$advisory_severities")"

printf '[INFO] Grype distro: %s %s\n' "$actual_name" "$actual_version"
printf '[INFO] Scope Fedora RPM matches: %s\n' "$scope_matches"
printf '[INFO] Fixable advisory matches: %s\n' "$advisory"
printf '[INFO] Fixable blocking matches: %s\n' "$blocked"

summary_file="${GITHUB_STEP_SUMMARY:-}"
if [[ -n "$summary_file" ]]; then
  {
    echo "### Fedora/OSTree vulnerability gate"
    echo
    echo "- Distro detectada: **$actual_name $actual_version**"
    echo "- Matches en scope Fedora RPM: **$scope_matches**"
    echo "- High corregibles (advisory): **$advisory**"
    echo "- Critical corregibles (bloqueantes): **$blocked**"
  } >> "$summary_file"
fi

if (( advisory > 0 )); then
  echo "[WARN] Fedora RPM High corregibles (advisory):"
  jq -r     --arg artifact_type "$artifact_type"     --arg namespace_prefix "$namespace_prefix"     --arg fix_state "$fix_state"     --argjson severities "$advisory_severities"     '.matches[]?
      | select(.artifact.type == $artifact_type)
      | select((.vulnerability.namespace // "") | startswith($namespace_prefix))
      | select(.vulnerability.fix.state == $fix_state)
      | select((.vulnerability.fix.versions // []) | length > 0)
      | select(.vulnerability.severity as $sev | $severities | index($sev))
      | [
          .vulnerability.severity,
          .vulnerability.id,
          .artifact.name,
          .artifact.version,
          (.vulnerability.fix.versions | join(","))
        ]
      | @tsv' "$REPORT" | sort -u
fi

if (( blocked > 0 )); then
  echo "[ERROR] Vulnerabilidades bloqueantes Fedora RPM:"
  jq -r     --arg artifact_type "$artifact_type"     --arg namespace_prefix "$namespace_prefix"     --arg fix_state "$fix_state"     --argjson severities "$block_severities"     '.matches[]?
      | select(.artifact.type == $artifact_type)
      | select((.vulnerability.namespace // "") | startswith($namespace_prefix))
      | select(.vulnerability.fix.state == $fix_state)
      | select((.vulnerability.fix.versions // []) | length > 0)
      | select(.vulnerability.severity as $sev | $severities | index($sev))
      | [
          .vulnerability.severity,
          .vulnerability.id,
          .artifact.name,
          .artifact.version,
          (.vulnerability.fix.versions | join(","))
        ]
      | @tsv' "$REPORT" | sort -u >&2
  exit 1
fi

echo "[INFO] Security gate aprobado."
