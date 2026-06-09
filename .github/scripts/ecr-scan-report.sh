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

# ---- Scratch tree ----
# Holds raw per-page AWS responses and the merged findings file. Keeping all
# findings out of shell variables (and thus out of any spawned process's argv)
# is what prevents the ARG_MAX overflow that broke this script on high-finding
# images. See openspec/changes/fix-ecr-scan-arg-list-overflow/ for the spec.
SCRATCH="$(mktemp -d -t izg-ecr-scan.XXXXXX)"
# Scratch files are removed on exit. To retain them for local debugging,
# comment out the trap below and re-run; the directory path is printed in the
# "Scratch dir" log line just below.
trap 'rm -rf "$SCRATCH"' EXIT

# ---- Derive names ----
# Extract semver from tag: "2.4.0-RELEASE-42" or plain "2.4.0" both yield "2.4.0"
VERSION="${TAG%%-RELEASE-*}"

# CDC date prefix: YYYY-MM-DD -> YYYYMMDD
DATE_PREFIX="${RELEASE_DATE//-/}"

ARTIFACT_BASE="${OUT_DIR}/${DATE_PREFIX}_${PKG}_v${VERSION}_InspectorScan"
ALL_FINDINGS="${SCRATCH}/all-findings.json"

echo "ECR repo:     $REPO"
echo "Image tag:    $TAG"
echo "Version:      $VERSION"
echo "Release date: $RELEASE_DATE"
echo "Scratch dir:  $SCRATCH"
echo "Output base:  $ARTIFACT_BASE"

# ---- Build Inspector2 filter ----
FILTER_CRITERIA=$(jq -n \
  --arg repo "$REPO" \
  --arg tag  "$TAG" \
  '{
    ecrImageRepositoryName: [{ comparison: "EQUALS", value: $repo }],
    ecrImageTags:            [{ comparison: "EQUALS", value: $tag  }]
  }')

# ---- Paginate Inspector2 findings, streaming each page to its own file ----
# Findings never live in a shell variable. Each AWS response is written
# straight to disk, and the merge step at the end uses jq -s over a glob to
# combine pages — both inputs flow through file I/O, never argv.
echo "Fetching findings from Inspector2..."

PAGE_NUM=0
NEXT_TOKEN=""

while true; do
  PAGE_FILE=$(printf '%s/page-%04d.json' "$SCRATCH" "$PAGE_NUM")

  if [[ -n "$NEXT_TOKEN" ]]; then
    aws inspector2 list-findings \
      --filter-criteria "$FILTER_CRITERIA" \
      --max-results 100 \
      --next-token "$NEXT_TOKEN" \
      --output json > "$PAGE_FILE"
  else
    aws inspector2 list-findings \
      --filter-criteria "$FILTER_CRITERIA" \
      --max-results 100 \
      --output json > "$PAGE_FILE"
  fi

  NEXT_TOKEN=$(jq -r '.nextToken // empty' "$PAGE_FILE")
  PAGE_NUM=$((PAGE_NUM + 1))
  [[ -z "$NEXT_TOKEN" ]] && break
done

# Merge per-page responses into a single { findings: [...] } envelope.
jq -s 'map(.findings[]) | { findings: . }' "$SCRATCH"/page-*.json > "$ALL_FINDINGS"

echo "Total findings fetched: $(jq '.findings | length' "$ALL_FINDINGS")"

# ---- Filter to vendorCreatedAt <= release-date, write JSON output ----
echo "Filtering findings to vendorCreatedAt <= $RELEASE_DATE ..."

jq --arg cutoff "$RELEASE_DATE" '
  .findings |= map(select(
    (.packageVulnerabilityDetails.vendorCreatedAt // "9999-12-31T00:00:00Z") |
    split("T")[0] <= $cutoff
  ))
' "$ALL_FINDINGS" > "${ARTIFACT_BASE}.json"

echo "Findings after release-date filter: $(jq '.findings | length' "${ARTIFACT_BASE}.json")"
echo "Written: ${ARTIFACT_BASE}.json"

# ---- Write CSV ----
# Rows are emitted at one-per-(name, packageManager, version, fixedInVersion)
# tuple per finding. vulnerablePackages entries that differ only by filePath
# (e.g., the same Go binary at /usr/bin/foo and /foo/foo) collapse into a
# single row whose File Paths cell lists all paths. See design.md D6.
jq -r '
  ["CVE ID","Severity","CVSS Score","CVE Date","Package","Package Manager","Installed Version","Fixed In","File Paths","Description"],
  (.findings[] |
    . as $f |
    ($f.packageVulnerabilityDetails.cvss |
      map(select(.source == "NVD")) | first //
      $f.packageVulnerabilityDetails.cvss[0] //
      {"baseScore": null}
    ) as $cvss |
    ($f.packageVulnerabilityDetails.vulnerablePackages // [{}])
    | group_by([(.name // ""), (.packageManager // ""), (.version // ""), (.fixedInVersion // "")])
    | .[]
    | . as $group
    | ($group[0]) as $p
    | ($group | map(.filePath // "") | unique | map(select(. != "")) | join(", ")) as $paths
    | [
        ($f.packageVulnerabilityDetails.vulnerabilityId // ""),
        ($f.severity // ""),
        ($cvss.baseScore | if . == null then "" else tostring end),
        ($f.packageVulnerabilityDetails.vendorCreatedAt | if . then split("T")[0] else "" end),
        ($p.name // ""),
        ($p.packageManager // ""),
        ($p.version // ""),
        ($p.fixedInVersion // ""),
        $paths,
        ($f.description // "" | gsub("\n"; " ") | gsub(","; ";"))
      ]
  ) |
  @csv
' "${ARTIFACT_BASE}.json" > "${ARTIFACT_BASE}.csv"
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
