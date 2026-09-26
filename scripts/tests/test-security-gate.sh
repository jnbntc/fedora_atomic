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

echo "OK: Fedora advisory gate bloquea Critical/Important y permite Moderate/Low."
