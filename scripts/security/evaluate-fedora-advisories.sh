#!/usr/bin/env bash
set -Eeuo pipefail

REPORT="${1:-security-evidence/fedora-security-advisories.json}"
POLICY="${2:-security/vulnerability-policy.json}"

die() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 2
}

command -v jq >/dev/null 2>&1 || die "jq no está disponible"
[[ -f "$REPORT" ]] || die "No existe el reporte DNF5: $REPORT"
[[ -f "$POLICY" ]] || die "No existe la política: $POLICY"

jq -e 'type == "array"' "$REPORT" >/dev/null   || die "Reporte DNF5 inválido: se esperaba un array JSON"

jq -e '
  .schema_version == 1
  and .engine == "dnf5-advisory"
  and (.expected_distro.name | type == "string" and length > 0)
  and (.expected_distro.version | type == "string" and length > 0)
  and .scope.mode == "available"
  and .scope.type == "security"
  and (.block_severities | type == "array" and length > 0)
  and (.advisory_severities | type == "array")
  and all(
    (.block_severities + .advisory_severities)[];
    (. | ascii_downcase) as $severity
    | ["critical", "important", "moderate", "low"]
    | index($severity)
  )
  and (
    [
      .block_severities[] | ascii_downcase
    ] as $block
    | [
        .advisory_severities[] | ascii_downcase
      ] as $advisory
    | [$block[] | select(. as $s | $advisory | index($s))] | length == 0
  )
' "$POLICY" >/dev/null   || die "Política de vulnerabilidades inválida o inconsistente"

if ! jq -e '
  all(.[];
    (.advisory_type // "" | ascii_downcase) == "security"
    and (.advisory_name // "") != ""
    and (.advisory_severity // "") != ""
    and (.nevra // "") != ""
  )
' "$REPORT" >/dev/null; then
  die "El reporte contiene filas que no son advisories de seguridad DNF5 válidos"
fi

block_severities="$(jq -c '.block_severities | map(ascii_downcase)' "$POLICY")"
advisory_severities="$(jq -c '.advisory_severities | map(ascii_downcase)' "$POLICY")"

count_unique_advisories() {
  local severities="$1"

  jq     --argjson severities "$severities"     '[
      .[]
      | select(
          (.advisory_severity | ascii_downcase) as $severity
          | $severities
          | index($severity)
        )
      | .advisory_name
    ]
    | unique
    | length' "$REPORT"
}

total_advisories="$(jq '[.[].advisory_name] | unique | length' "$REPORT")"
total_cves="$(
  jq '[
    .[].references[]?
    | select((.reference_type // "" | ascii_downcase) == "cve")
    | .reference_id
  ] | unique | length' "$REPORT"
)"
blocked="$(count_unique_advisories "$block_severities")"
advisory="$(count_unique_advisories "$advisory_severities")"

printf '[INFO] Fedora security advisories available: %s\n' "$total_advisories"
printf '[INFO] CVE references: %s\n' "$total_cves"
printf '[INFO] Moderate/Low advisory: %s\n' "$advisory"
printf '[INFO] Critical/Important blocking: %s\n' "$blocked"

summary_file="${GITHUB_STEP_SUMMARY:-}"
if [[ -n "$summary_file" ]]; then
  {
    echo "### Fedora native security gate"
    echo
    echo "- Security advisories disponibles: **$total_advisories**"
    echo "- CVE referenciadas: **$total_cves**"
    echo "- Moderate/Low (advisory): **$advisory**"
    echo "- Critical/Important (bloqueantes): **$blocked**"
  } >>"$summary_file"
fi

print_advisories() {
  local severities="$1"

  jq -r     --argjson severities "$severities"     '.[] 
      | select(
          (.advisory_severity | ascii_downcase) as $severity
          | $severities
          | index($severity)
        )
      | [
          .advisory_severity,
          .advisory_name,
          .nevra,
          (
            [
              .references[]?
              | select((.reference_type // "" | ascii_downcase) == "cve")
              | .reference_id
            ]
            | unique
            | join(",")
          )
        ]
      | @tsv' "$REPORT" | sort -u
}

if (( advisory > 0 )); then
  echo "[WARN] Fedora Moderate/Low con actualización de seguridad disponible:"
  print_advisories "$advisory_severities"
fi

if (( blocked > 0 )); then
  echo "[ERROR] Fedora Critical/Important con actualización de seguridad disponible:" >&2
  print_advisories "$block_severities" >&2
  exit 1
fi

echo "[INFO] Fedora security gate aprobado."
