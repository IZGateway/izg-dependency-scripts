# inspector2-scan-report.jq — Inspector2 list-findings JSON → self-contained HTML report
# Consumes the {"findings": [...]} envelope written by ecr-scan-report.sh.
# Rows sorted by CVSS score descending, then severity order.
#
# Arguments (via --arg):
#   service     GitHub package name / service display name (e.g. "izgw-hub")
#   version     Image version (e.g. "2.4.0")
#   scan_date   Release date string (YYYY-MM-DD)
#
# Usage:
#   jq -rf inspector2-scan-report.jq \
#       --arg service "izgw-hub" \
#       --arg version "2.4.0" \
#       --arg scan_date "2026-05-14" \
#       YYYYMMDD_izgw-hub_v2.4.0_InspectorScan.json > YYYYMMDD_izgw-hub_v2.4.0_InspectorScan.html

def esc:
  if . == null then ""
  elif type == "number" then tostring
  else tostring | gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;")
  end;

def severity_order:
  if . == "CRITICAL" then 0
  elif . == "HIGH"     then 1
  elif . == "MEDIUM"   then 2
  elif . == "LOW"      then 3
  elif . == "INFO"     then 4
  else 5 end;

# Normalise Inspector2 list-findings findings into display rows.
# Input: {"findings": [...]} envelope.
#
# Within each finding, vulnerablePackages entries are grouped by
# (name, packageManager, version, fixedInVersion) so that the same package
# installed at multiple file paths collapses into one row with all paths
# joined into the filePaths field. Paths are HTML-escaped individually so
# the literal <br> separators survive when rendered in the table cell.
# See design.md D6.
def normalise_findings:
  .findings[] |
  . as $f |
  ($f.packageVulnerabilityDetails.cvss |
    map(select(.source == "NVD")) | first //
    $f.packageVulnerabilityDetails.cvss[0] //
    {baseScore: null}
  ) as $cvss |
  ($f.packageVulnerabilityDetails.vulnerablePackages // [{}])
  | group_by([(.name // ""), (.packageManager // ""), (.version // ""), (.fixedInVersion // "")])
  | .[]
  | . as $group
  | ($group[0]) as $p
  | ($group | map(.filePath // "") | unique | map(select(. != "")) | map(esc) | join("<br>")) as $paths
  | {
      cveId:       ($f.packageVulnerabilityDetails.vulnerabilityId // ""),
      severity:    ($f.severity // ""),
      score:       ($cvss.baseScore // -1),
      cveDate:     ($f.packageVulnerabilityDetails.vendorCreatedAt | if . then split("T")[0] else "" end),
      pkgName:     ($p.name // ""),
      pkgManager:  ($p.packageManager // ""),
      installed:   ($p.version // ""),
      fixedIn:     ($p.fixedInVersion // ""),
      filePaths:   $paths,
      description: ($f.description // "")
    };

[normalise_findings] |
sort_by([-(.score), (.severity | severity_order)]) |

"<!DOCTYPE html>\n<html>\n<head>\n<meta charset=\"utf-8\">\n<title>Inspector2 Scan Report — \($service) v\($version)</title>\n<style>\n  body { font-family: Arial, sans-serif; font-size: 13px; color: #222; }\n  h2 { color: #003366; }\n  table { border-collapse: collapse; width: 100%; margin-top: 1em; }\n  th { background-color: #003366; color: white; padding: 6px 8px; text-align: left; }\n  td { padding: 5px 8px; border: 1px solid #ccc; vertical-align: top; }\n  tr:nth-child(even) { background-color: #f5f5f5; }\n  .meta { margin-bottom: 1em; }\n  .sev-CRITICAL { color: #8b0000; font-weight: bold; }\n  .sev-HIGH     { color: #cc4400; font-weight: bold; }\n  .sev-MEDIUM   { color: #cc8800; }\n  .sev-LOW      { color: #558800; }\n</style>\n</head>\n<body>\n<h2>IZ Gateway ECR Image Scan Report</h2>\n<div class=\"meta\">\n  <strong>Service:</strong> \($service | esc)<br>\n  <strong>Version:</strong> v\($version | esc)<br>\n  <strong>Scan Date:</strong> \($scan_date | esc)<br>\n  <strong>Total Findings:</strong> \(length)\n</div>",

if length == 0 then
  "<p><em>No findings reported.</em></p>"
else
  "<table>\n  <thead>\n    <tr>\n      <th>CVE ID</th>\n      <th>Severity</th>\n      <th>CVSS Score</th>\n      <th>CVE Date</th>\n      <th>Package Name</th>\n      <th>Package Manager</th>\n      <th>Installed Version</th>\n      <th>Fixed In</th>\n      <th>File Paths</th>\n      <th>Description</th>\n    </tr>\n  </thead>\n  <tbody>",
  (.[] |
    "    <tr><td><a href=\"https://nvd.nist.gov/vuln/detail/\(.cveId | esc)\">\(.cveId | esc)</a></td><td class=\"sev-\(.severity | esc)\">\(.severity | esc)</td><td>\(if .score < 0 then "" else .score | tostring end)</td><td>\(.cveDate | esc)</td><td>\(.pkgName | esc)</td><td>\(.pkgManager | esc)</td><td>\(.installed | esc)</td><td>\(if .fixedIn == "" then "<em>None</em>" else .fixedIn | esc end)</td><td>\(.filePaths)</td><td>\(.description | esc)</td></tr>"
  ),
  "  </tbody>\n</table>"
end,
"</body>\n</html>"
