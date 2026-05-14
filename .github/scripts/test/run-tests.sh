#!/usr/bin/env bash
# run-tests.sh — local verification for ecr-scan-report scripts.
# Runs jq filters against fixture JSON and checks output for expected content.
#
# Usage (from repo root or this directory):
#   bash .github/scripts/test/run-tests.sh
#
# Prerequisites: jq on PATH
# No AWS credentials required — uses local fixture files.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="${SCRIPT_DIR}/.."

PASS=0
FAIL=0

ok()   { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# ---- Test 1: inspector2-scan-report.jq produces valid HTML ----
echo "Test 1: inspector2-scan-report.jq"
HTML=$(jq -rf "${SCRIPTS}/inspector2-scan-report.jq" \
  --arg service "izgw-hub" \
  --arg version "2.4.0" \
  --arg scan_date "2026-05-14" \
  "${SCRIPT_DIR}/fixture-inspector2.json")

echo "$HTML" | grep -q "<!DOCTYPE html>" && ok "has DOCTYPE" || fail "missing DOCTYPE"
echo "$HTML" | grep -q "izgw-hub"        && ok "service name present" || fail "service name missing"
echo "$HTML" | grep -q "v2.4.0"          && ok "version present" || fail "version missing"
echo "$HTML" | grep -q "nvd.nist.gov"    && ok "NVD link present" || fail "NVD link missing"
echo "$HTML" | grep -q "sev-"            && ok "severity CSS class present" || fail "severity CSS missing"

# ---- Test 2: inspector2-scan-report.jq empty findings produces no-findings message ----
echo ""
echo "Test 2: inspector2-scan-report.jq empty input"
EMPTY_HTML=$(echo '{"findings":[]}' | jq -rf "${SCRIPTS}/inspector2-scan-report.jq" \
  --arg service "test" --arg version "1.0.0" --arg scan_date "2026-01-01")

echo "$EMPTY_HTML" | grep -q "No findings reported" && ok "empty findings message present" || fail "empty findings message missing"

# ---- Test 3: ecr-scan-report.jq (legacy ECR format) ----
echo ""
echo "Test 3: ecr-scan-report.jq (basic ECR format)"
if [[ -f "${SCRIPT_DIR}/fixture-ecr-basic.json" ]]; then
  ECR_HTML=$(jq -rf "${SCRIPTS}/ecr-scan-report.jq" \
    --arg service "test-service" \
    --arg version "1.0.0" \
    --arg scan_date "2026-05-14" \
    "${SCRIPT_DIR}/fixture-ecr-basic.json")
  echo "$ECR_HTML" | grep -q "<!DOCTYPE html>" && ok "ECR basic: has DOCTYPE" || fail "ECR basic: missing DOCTYPE"
else
  echo "  SKIP: fixture-ecr-basic.json not present (run fetch-fixtures.sh to create)"
fi

# ---- Summary ----
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
