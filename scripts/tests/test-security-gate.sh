#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
EVALUATOR="${ROOT_DIR}/scripts/security/evaluate-fedora-advisories.sh"
POLICY="${ROOT_DIR}/security/vulnerability-policy.json"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

empty_report="${TMP_DIR}/empty.json"
advisory_report="${TMP_DIR}/advisory.json"
critical_report="${TMP_DIR}/critical.json"
important_report="${TMP_DIR}/important.json"
invalid_report="${TMP_DIR}/invalid.json"

printf '[]\n' >"$empty_report"
bash "$EVALUATOR" "$empty_report" "$POLICY" >/dev/null

cat >"$advisory_report" <<'JSON'
[
  {
    "advisory_name": "FEDORA-LOW",
    "advisory_type": "security",
    "advisory_severity": "Low",
    "nevra": "pkg-low-1.1-1.fc44.x86_64",
    "references": [
      {"reference_id": "CVE-LOW", "reference_type": "cve"}
    ]
  },
  {
    "advisory_name": "FEDORA-MODERATE",
    "advisory_type": "security",
    "advisory_severity": "Moderate",
    "nevra": "pkg-moderate-1.1-1.fc44.x86_64",
    "references": [
      {"reference_id": "CVE-MODERATE", "reference_type": "cve"}
    ]
  }
]
JSON
bash "$EVALUATOR" "$advisory_report" "$POLICY" >/dev/null

cat >"$critical_report" <<'JSON'
[
  {
    "advisory_name": "FEDORA-CRITICAL",
    "advisory_type": "security",
    "advisory_severity": "Critical",
    "nevra": "pkg-critical-2.0-1.fc44.x86_64",
    "references": [
      {"reference_id": "CVE-CRITICAL", "reference_type": "cve"}
    ]
  }
]
JSON
if bash "$EVALUATOR" "$critical_report" "$POLICY" >/dev/null 2>&1; then
  echo "FAIL: el gate permitió un advisory Critical" >&2
  exit 1
fi

cat >"$important_report" <<'JSON'
[
  {
    "advisory_name": "FEDORA-IMPORTANT",
    "advisory_type": "security",
    "advisory_severity": "Important",
    "nevra": "pkg-important-3.0-1.fc44.x86_64",
    "references": [
      {"reference_id": "CVE-IMPORTANT", "reference_type": "cve"}
    ]
  },
  {
    "advisory_name": "FEDORA-IMPORTANT",
    "advisory_type": "security",
    "advisory_severity": "Important",
    "nevra": "pkg-important-libs-3.0-1.fc44.x86_64",
    "references": [
      {"reference_id": "CVE-IMPORTANT", "reference_type": "cve"}
    ]
  }
]
JSON
if bash "$EVALUATOR" "$important_report" "$POLICY" >/dev/null 2>&1; then
  echo "FAIL: el gate permitió un advisory Important" >&2
  exit 1
fi

cat >"$invalid_report" <<'JSON'
[
  {
    "advisory_name": "FEDORA-BUGFIX",
    "advisory_type": "bugfix",
    "advisory_severity": "Important",
    "nevra": "pkg-1.0-1.fc44.x86_64",
    "references": []
  }
]
JSON
if bash "$EVALUATOR" "$invalid_report" "$POLICY" >/dev/null 2>&1; then
  echo "FAIL: el gate aceptó filas fuera del scope security" >&2
  exit 1
fi

invalid_policy="${TMP_DIR}/invalid-policy.json"
jq '.advisory_severities += ["critical"]' "$POLICY" >"$invalid_policy"

if bash "$EVALUATOR" "$empty_report" "$invalid_policy" >/dev/null 2>&1; then
  echo "FAIL: el gate aceptó una política con severidades superpuestas" >&2
  exit 1
fi

echo "OK: Fedora advisory gate bloquea Critical/Important, permite Moderate/Low y valida la política."


# ---------------------------------------------------------------------------
# Invariantes del workflow de producción
# ---------------------------------------------------------------------------
workflow="${ROOT_DIR}/.github/workflows/build.yml"

if grep -Fq 'aquasecurity/trivy-action' "$workflow"; then
  echo "FAIL: build.yml todavía usa el Trivy archive scan incompatible con Fedora/OSTree" >&2
  exit 1
fi

if grep -Fq 'podman save --format docker-archive' "$workflow"; then
  echo "FAIL: build.yml todavía exporta docker-archive para seguridad" >&2
  exit 1
fi

grep -Fq 'anchore/sbom-action/download-syft@3ad7283483fc7af8ff2b4ea19663c2d5ca935e26' "$workflow" || {
  echo "FAIL: falta Syft action pinneada" >&2
  exit 1
}

grep -Fq 'syft-version: v1.52.0' "$workflow" || {
  echo "FAIL: falta pin de Syft v1.52.0" >&2
  exit 1
}

grep -Fq 'spdx-json=security-evidence/sbom.spdx.json' "$workflow" || {
  echo "FAIL: falta SBOM SPDX" >&2
  exit 1
}

grep -Fq 'cyclonedx-json=security-evidence/sbom.cyclonedx.json' "$workflow" || {
  echo "FAIL: falta SBOM CycloneDX" >&2
  exit 1
}

grep -Fq 'anchore/scan-action@27805bf3b4e84b4a5c980df22ed233c00390a439' "$workflow" || {
  echo "FAIL: falta Grype action pinneada" >&2
  exit 1
}

grep -Fq 'grype-version: v0.119.0' "$workflow" || {
  echo "FAIL: falta pin de Grype v0.119.0" >&2
  exit 1
}

grep -Fq 'dnf5 --refresh advisory list' "$workflow" || {
  echo "FAIL: falta consulta Fedora-native de advisories" >&2
  exit 1
}

grep -Fq 'actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02' "$workflow" || {
  echo "FAIL: falta upload-artifact pinneado" >&2
  exit 1
}

gate_line="$(grep -n 'Enforce Fedora Security Gate' "$workflow" | cut -d: -f1)"
push_line="$(grep -n 'Push Built Image' "$workflow" | cut -d: -f1)"

[[ -n "$gate_line" && -n "$push_line" && "$gate_line" -lt "$push_line" ]] || {
  echo "FAIL: el security gate debe ejecutarse antes del push" >&2
  exit 1
}

grep -Fq '      - security/**' "$workflow" || {
  echo "FAIL: cambios de política no disparan build en main" >&2
  exit 1
}

grep -Fq '      - scripts/security/**' "$workflow" || {
  echo "FAIL: cambios del evaluator no disparan build en main" >&2
  exit 1
}

echo "OK: workflow de producción conserva los invariantes de Etapa 5."
