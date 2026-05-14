#!/usr/bin/env bash
# ecr-scan-report.sh — fetch Inspector2 findings for an ECR image and generate
# JSON, CSV, and HTML scan report files using the CDC naming convention.
#
# Usage:
#   ecr-scan-report.sh \
#     --repo         <ecr-repository-name> \
#     --tag          <image-tag> \
#     --pkg          <gh-pkg-name> \
#     --release-date <YYYY-MM-DD> \
#     --out-dir      <output-directory>
#
# Outputs (written to <out-dir>):
#   YYYYMMDD_{pkg}_v{version}_InspectorScan.json  — filtered findings envelope
#   YYYYMMDD_{pkg}_v{version}_InspectorScan.csv   — one row per CVE/package pair
#   YYYYMMDD_{pkg}_v{version}_InspectorScan.html  — self-contained sortable table
#
# Requires: aws CLI, jq
# IAM: inspector2:ListFindings on the caller's OIDC role

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---- Parse arguments ----
REPO=""
TAG=""
PKG=""
RELEASE_DATE=""
OUT_DIR="."

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)         REPO="$2";         shift 2 ;;
    --tag)          TAG="$2";          shift 2 ;;
    --pkg)          PKG="$2";          shift 2 ;;
    --release-date) RELEASE_DATE="$2"; shift 2 ;;
    --out-dir)      OUT_DIR="$2";      shift 2 ;;
    *) echo "ERROR: Unknown argument: $1" >&2; exit 1 ;;
  esac
done

[[ -z "$REPO"         ]] && { echo "ERROR: --repo is required"         >&2; exit 1; }
[[ -z "$TAG"          ]] && { echo "ERROR: --tag is required"          >&2; exit 1; }
[[ -z "$PKG"          ]] && { echo "ERROR: --pkg is required"          >&2; exit 1; }
[[ -z "$RELEASE_DATE" ]] && { echo "ERROR: --release-date is required" >&2; exit 1; }

mkdir -p "$OUT_DIR"

# ---- Derive names ----
# Extract semver from tag: 2.4.0-RELEASE-42 -> 2.4.0
VERSION="${TAG%%-RELEASE-*}"

# CDC date prefix: YYYY-MM-DD -> YYYYMMDD
DATE_PREFIX="${RELEASE_DATE//-/}"

ARTIFACT_BASE="${OUT_DIR}/${DATE_PREFIX}_${PKG}_v${VERSION}_InspectorScan"

echo "ECR repo:     $REPO"
echo "Image tag:    $TAG"
echo "Version:      $VERSION"
echo "Release date: $RELEASE_DATE"
echo "Output base:  $ARTIFACT_BASE"

# ---- Fetch all findings from Inspector2 (paginated) ----
echo "Fetching findings from Inspector2..."

FILTER_CRITERIA=$(jq -n \
  --arg repo "$REPO" \
  --arg tag  "$TAG" \
  '{
    ecrImageRepositoryName: [{ comparison: "EQUALS", value: $repo }],
    ecrImageTags:            [{ comparison: "EQUALS", value: $tag  }]
  }')

FINDINGS_ALL="[]"
NEXT_TOKEN=""

while true; do
  if [[ -n "$NEXT_TOKEN" ]]; then
    PAGE=$(aws inspector2 list-findings \
      --filter-criteria "$FILTER_CRITERIA" \
      --max-results 100 \
      --next-token "$NEXT_TOKEN" \
      --output json)
  else
    PAGE=$(aws inspector2 list-findings \
      --filter-criteria "$FILTER_CRITERIA" \
      --max-results 100 \
      --output json)
  fi

  PAGE_FINDINGS=$(echo "$PAGE" | jq '.findings')
  FINDINGS_ALL=$(jq -n --argjson a "$FINDINGS_ALL" --argjson b "$PAGE_FINDINGS" '$a + $b')

  NEXT_TOKEN=$(echo "$PAGE" | jq -r '.nextToken // empty')
  [[ -z "$NEXT_TOKEN" ]] && break
done

echo "Total findings fetched: $(echo "$FINDINGS_ALL" | jq 'length')"

# ---- Filter to vendorCreatedAt <= release-date ----
echo "Filtering findings to vendorCreatedAt <= $RELEASE_DATE ..."

FINDINGS_FILTERED=$(echo "$FINDINGS_ALL" | jq --arg cutoff "$RELEASE_DATE" '
  map(select(
    (.packageVulnerabilityDetails.vendorCreatedAt // "9999-12-31T00:00:00Z") |
    split("T")[0] <= $cutoff
  ))
')

echo "Findings after release-date filter: $(echo "$FINDINGS_FILTERED" | jq 'length')"

# ---- Write JSON ----
echo "$FINDINGS_FILTERED" | jq '{"findings": .}' > "${ARTIFACT_BASE}.json"
echo "Written: ${ARTIFACT_BASE}.json"

# ---- Write CSV ----
echo "$FINDINGS_FILTERED" | jq -r '
  ["CVE ID","Severity","CVSS Score","CVE Date","Package","Installed Version","Fixed In","Description"],
  (.[] |
    . as $f |
    ($f.packageVulnerabilityDetails.cvss |
      map(select(.source == "NVD")) | first //
      $f.packageVulnerabilityDetails.cvss[0] //
      {"baseScore": null}
    ) as $cvss |
    ($f.packageVulnerabilityDetails.vulnerablePackages // [{}]) | .[] |
    [
      ($f.packageVulnerabilityDetails.vulnerabilityId // ""),
      ($f.severity // ""),
      ($cvss.baseScore | if . == null then "" else tostring end),
      ($f.packageVulnerabilityDetails.vendorCreatedAt | if . then split("T")[0] else "" end),
      (.name // ""),
      (.version // ""),
      (.fixedInVersion // ""),
      ($f.description // "" | gsub("\n"; " ") | gsub(","; ";"))
    ]
  ) |
  @csv
' > "${ARTIFACT_BASE}.csv"
echo "Written: ${ARTIFACT_BASE}.csv"

# ---- Write HTML (via inspector2-scan-report.jq) ----
jq -rf "${SCRIPT_DIR}/inspector2-scan-report.jq" \
  --arg service   "$PKG" \
  --arg version   "$VERSION" \
  --arg scan_date "$RELEASE_DATE" \
  "${ARTIFACT_BASE}.json" > "${ARTIFACT_BASE}.html"
echo "Written: ${ARTIFACT_BASE}.html"

echo ""
echo "Done. Output files:"
ls -lh "${ARTIFACT_BASE}".{json,csv,html}
