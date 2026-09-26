#!/usr/bin/env bash
set -Eeuo pipefail

REPORT="grype-report.json"
SBOM="sbom.spdx.json"
SUMMARY="security-summary.md"
EXPECTED_DISTRO="fedora"
EXPECTED_VERSION="44"
REPORT_ONLY=0

log()  { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die()  { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Uso:
  security-gate.sh [opciones]

Opciones:
  --report FILE              Reporte JSON de Grype (default: grype-report.json)
  --sbom FILE                SBOM SPDX JSON (default: sbom.spdx.json)
  --summary FILE             Resumen Markdown (default: security-summary.md)
  --expected-distro NAME     Distro esperada (default: fedora)
  --expected-version VERSION Versión esperada (default: 44)
  --report-only              Genera resumen pero no bloquea por CVE.
  -h, --help                 Muestra esta ayuda.

Política:
  Bloquea la publicación cuando existe al menos una vulnerabilidad HIGH o
  CRITICAL con fix disponible, asociada a un paquete RPM mediante el namespace
  específico de Fedora. Hallazgos de otros ecosistemas/CPE se reportan de
  forma advisory porque pueden corresponder a dependencias embebidas y
  coincidencias de menor confianza.
EOF
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Falta el comando requerido: $1"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --report)
      [[ $# -ge 2 ]] || die "--report requiere un valor"
      REPORT="$2"
      shift 2
      ;;
    --sbom)
      [[ $# -ge 2 ]] || die "--sbom requiere un valor"
      SBOM="$2"
      shift 2
      ;;
    --summary)
      [[ $# -ge 2 ]] || die "--summary requiere un valor"
      SUMMARY="$2"
      shift 2
      ;;
    --expected-distro)
      [[ $# -ge 2 ]] || die "--expected-distro requiere un valor"
      EXPECTED_DISTRO="$2"
      shift 2
      ;;
    --expected-version)
      [[ $# -ge 2 ]] || die "--expected-version requiere un valor"
      EXPECTED_VERSION="$2"
      shift 2
      ;;
    --report-only)
      REPORT_ONLY=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Opción desconocida: $1"
      ;;
  esac
done

require_cmd jq

[[ -s "$REPORT" ]] || die "Reporte Grype inexistente o vacío: $REPORT"
[[ -s "$SBOM" ]] || die "SBOM inexistente o vacío: $SBOM"

jq -e '.matches | type == "array"' "$REPORT" >/dev/null   || die "El reporte de Grype no contiene un array .matches válido"

jq -e '.packages | type == "array"' "$SBOM" >/dev/null   || die "El SBOM no contiene un array .packages válido"

distro="$(jq -r '.distro.name // empty' "$REPORT")"
version="$(jq -r '.distro.version // empty' "$REPORT")"
spdx_version="$(jq -r '.spdxVersion // empty' "$SBOM")"
package_count="$(jq '.packages | length' "$SBOM")"
rpm_package_count="$(
  jq '[
    .packages[]?
    | select(
        any(
          .externalRefs[]?;
          .referenceType == "purl"
          and (.referenceLocator | startswith("pkg:rpm/"))
        )
      )
  ] | length' "$SBOM"
)"

total_matches="$(jq '.matches | length' "$REPORT")"
critical_count="$(jq '[.matches[]? | select(.vulnerability.severity == "Critical")] | length' "$REPORT")"
high_count="$(jq '[.matches[]? | select(.vulnerability.severity == "High")] | length' "$REPORT")"
medium_count="$(jq '[.matches[]? | select(.vulnerability.severity == "Medium")] | length' "$REPORT")"
low_count="$(jq '[.matches[]? | select(.vulnerability.severity == "Low")] | length' "$REPORT")"
unknown_count="$(jq '[.matches[]? | select(.vulnerability.severity == "Unknown")] | length' "$REPORT")"

fedora_rpm_matches="$(
  jq '[
    .matches[]?
    | select(
        .artifact.type == "rpm"
        and ((.vulnerability.namespace // "") | startswith("fedora"))
      )
  ] | length' "$REPORT"
)"

blocked_count="$(
  jq '[
    .matches[]?
    | select(
        .artifact.type == "rpm"
        and ((.vulnerability.namespace // "") | startswith("fedora"))
        and .vulnerability.fix.state == "fixed"
        and (
          .vulnerability.severity == "Critical"
          or .vulnerability.severity == "High"
        )
      )
  ] | length' "$REPORT"
)"

advisory_critical="$(
  jq '[
    .matches[]?
    | select(
        .vulnerability.severity == "Critical"
        and (
          .artifact.type != "rpm"
          or (((.vulnerability.namespace // "") | startswith("fedora")) | not)
          or .vulnerability.fix.state != "fixed"
        )
      )
  ] | length' "$REPORT"
)"

coverage_ok=1
coverage_reason="OK"

if [[ "$distro" != "$EXPECTED_DISTRO" || "$version" != "$EXPECTED_VERSION" ]]; then
  coverage_ok=0
  coverage_reason="Distro detectada: ${distro:-<vacía>} ${version:-<vacía>}; esperada: ${EXPECTED_DISTRO} ${EXPECTED_VERSION}"
elif [[ "$spdx_version" != "SPDX-2.3" ]]; then
  coverage_ok=0
  coverage_reason="SBOM inesperado: ${spdx_version:-<vacío>}; esperado SPDX-2.3"
elif (( rpm_package_count == 0 )); then
  coverage_ok=0
  coverage_reason="El SBOM no contiene paquetes RPM; el inventario no es confiable"
fi

{
  echo "# Security gate — Fedora Atomic"
  echo
  echo "- **Distro detectada:** ${distro:-unknown} ${version:-unknown}"
  echo "- **SBOM:** ${spdx_version:-unknown}, ${package_count} componentes, ${rpm_package_count} paquetes RPM"
  echo "- **Grype:** ${total_matches} hallazgos totales"
  echo "- **Severidades:** Critical=${critical_count}, High=${high_count}, Medium=${medium_count}, Low=${low_count}, Unknown=${unknown_count}"
  echo "- **Matches Fedora/RPM:** ${fedora_rpm_matches}"
  echo "- **Gate Fedora/RPM HIGH+CRITICAL con fix:** ${blocked_count}"
  echo "- **Critical advisory fuera del gate:** ${advisory_critical}"
  echo "- **Cobertura:** ${coverage_reason}"
  echo
  echo "## Política"
  echo
  echo "La publicación se bloquea únicamente ante vulnerabilidades **HIGH/CRITICAL con fix disponible**"
  echo "que Grype atribuya a paquetes **RPM** mediante el namespace específico de **Fedora**."
  echo "Los hallazgos de dependencias embebidas (Go/Python) y coincidencias CPE se conservan en el"
  echo "reporte completo como advisory para evitar bloquear por falsos positivos o por componentes"
  echo "que deben corregirse aguas arriba en Fedora."
} >"$SUMMARY"

if (( blocked_count > 0 )); then
  {
    echo
    echo "## Hallazgos que bloquean"
    echo
    echo "| Severidad | Vulnerabilidad | Paquete | Instalado | Fix |"
    echo "| --- | --- | --- | --- | --- |"
    jq -r '
      .matches[]?
      | select(
          .artifact.type == "rpm"
          and ((.vulnerability.namespace // "") | startswith("fedora"))
          and .vulnerability.fix.state == "fixed"
          and (
            .vulnerability.severity == "Critical"
            or .vulnerability.severity == "High"
          )
        )
      | [
          .vulnerability.severity,
          .vulnerability.id,
          .artifact.name,
          .artifact.version,
          (.vulnerability.fix.versions | join(", "))
        ]
      | "| " + join(" | ") + " |"
    ' "$REPORT" | sort -u
  } >>"$SUMMARY"
fi

log "Distro: ${distro:-unknown} ${version:-unknown}"
log "SBOM: ${spdx_version:-unknown}, componentes=${package_count}, rpm=${rpm_package_count}"
log "Grype: total=${total_matches}, critical=${critical_count}, high=${high_count}, medium=${medium_count}"
log "Fedora/RPM matches=${fedora_rpm_matches}; bloqueantes=${blocked_count}; advisory-critical=${advisory_critical}"

if (( REPORT_ONLY )); then
  if (( coverage_ok == 0 )); then
    warn "$coverage_reason"
  fi
  exit 0
fi

(( coverage_ok == 1 )) || die "$coverage_reason"

if (( blocked_count > 0 )); then
  cat "$SUMMARY" >&2
  die "Security gate bloqueado: ${blocked_count} vulnerabilidad(es) Fedora/RPM HIGH/CRITICAL con fix disponible."
fi

log "Security gate aprobado."
