#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
EVALUATOR="${ROOT_DIR}/scripts/security/evaluate-grype.sh"
POLICY="${ROOT_DIR}/security/vulnerability-policy.json"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

pass_report="${TMP_DIR}/pass.json"
fail_report="${TMP_DIR}/fail.json"
wrong_distro="${TMP_DIR}/wrong-distro.json"

cat >"$pass_report" <<'JSON'
{
  "distro": {"name": "fedora", "version": "44"},
  "matches": [
    {
      "artifact": {"name": "openssl-libs", "version": "1.0", "type": "rpm"},
      "vulnerability": {
        "id": "CVE-HIGH",
        "severity": "High",
        "namespace": "fedora:44",
        "fix": {"state": "fixed", "versions": ["1.1"]}
      }
    },
    {
      "artifact": {"name": "golang.org/x/crypto", "version": "0.1", "type": "go-module"},
      "vulnerability": {
        "id": "CVE-LANGUAGE",
        "severity": "Critical",
        "namespace": "govulndb:language:go",
        "fix": {"state": "fixed", "versions": ["0.2"]}
      }
    },
    {
      "artifact": {"name": "kernel", "version": "1.0", "type": "rpm"},
      "vulnerability": {
        "id": "CVE-UNFIXED",
        "severity": "Critical",
        "namespace": "fedora:44",
        "fix": {"state": "not-fixed", "versions": []}
      }
    }
  ]
}
JSON

bash "$EVALUATOR" "$pass_report" "$POLICY" >/dev/null

cat >"$fail_report" <<'JSON'
{
  "distro": {"name": "fedora", "version": "44"},
  "matches": [
    {
      "artifact": {"name": "rpm-critical", "version": "1.0", "type": "rpm"},
      "vulnerability": {
        "id": "CVE-BLOCK",
        "severity": "Critical",
        "namespace": "fedora:44",
        "fix": {"state": "fixed", "versions": ["1.1"]}
      }
    }
  ]
}
JSON

if bash "$EVALUATOR" "$fail_report" "$POLICY" >/dev/null 2>&1; then
  echo "FAIL: el gate permitió un Critical Fedora RPM corregible" >&2
  exit 1
fi

cat >"$wrong_distro" <<'JSON'
{
  "distro": {"name": "ubuntu", "version": "24.04"},
  "matches": []
}
JSON

if bash "$EVALUATOR" "$wrong_distro" "$POLICY" >/dev/null 2>&1; then
  echo "FAIL: el gate aceptó una distro inesperada" >&2
  exit 1
fi

echo "OK: vulnerability gate distingue scope, fix-state y distro."
