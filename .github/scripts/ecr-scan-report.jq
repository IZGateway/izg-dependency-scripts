# ecr-scan-report.jq — ECR describe-image-scan-findings JSON → self-contained HTML report
# Supports both AWS Inspector enhanced scanning (enhancedFindings) and
# basic ECR scanning (findings).
# Rows sorted by CVSS score descending, then severity order.
#
# Migrated from sprint-planning cve-scan-tooling design.
#
# Arguments (via --arg):
#   service     Service display name (e.g. "IZ Gateway Hub")
#   version     Image version tag (e.g. "2.4.0-RELEASE-42")
#   scan_date   Date string (YYYY-MM-DD)
#
# Usage:
#   jq -rf ecr-scan-report.jq \
#       --arg service "IZ Gateway Hub" \
#       --arg version "2.4.0-RELEASE-42" \
#       --arg scan_date "2026-05-14" \
#       ecr-scan.json > ecr-scan-report.html

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

# Normalise findings from either enhanced or basic ECR scan format into rows
def normalise_findings:
  if .imageScanFindings.enhancedFindings then
    # AWS Inspector enhanced scanning
    .imageScanFindings.enhancedFindings[] |
    . as $f |
    ($f.packageVulnerabilityDetails.cvss |
      map(select(.source == "NVD")) | first //
      $f.packageVulnerabilityDetails.cvss[0] //
      {baseScore: null, scoringVector: null}
    ) as $cvss |
    ($f.packageVulnerabilityDetails.vulnerablePackages // [{}]) | .[] |
    {
      cveId:       $f.packageVulnerabilityDetails.vulnerabilityId,
      severity:    $f.severity,
      score:       ($cvss.baseScore // -1),
      cveDate:     ($f.packageVulnerabilityDetails.vendorCreatedAt | if . then split("T")[0] else "" end),
      pkgName:     .name,
      installed:   .version,
      fixedIn:     (.fixedInVersion // ""),
      description: $f.description
    }
  else
    # Basic ECR scanning
    .imageScanFindings.findings[] |
    . as $f |
    (($f.attributes // []) | map(select(.key == "CVSS2_SCORE")) | first | .value | tonumber? // -1) as $score |
    (($f.attributes // []) | map(select(.key == "package_name"))     | first | .value // "") as $pkg |
    (($f.attributes // []) | map(select(.key == "package_version"))  | first | .value // "") as $ver |
    (($f.attributes // []) | map(select(.key == "fixed_in_version")) | first | .value // "") as $fix |
    {
      cveId:       $f.name,
      severity:    $f.severity,
      score:       $score,
      cveDate:     "",
      pkgName:     $pkg,
      installed:   $ver,
      fixedIn:     $fix,
      description: ($f.description // "")
    }
  end;

[normalise_findings] |
sort_by([-(.score), (.severity | severity_order)]) |

"<!DOCTYPE html>\n<html>\n<head>\n<meta charset=\"utf-8\">\n<title>ECR Scan Report — \($service) \($version)</title>\n<style>\n  body { font-family: Arial, sans-serif; font-size: 13px; color: #222; }\n  h2 { color: #003366; }\n  table { border-collapse: collapse; width: 100%; margin-top: 1em; }\n  th { background-color: #003366; color: white; padding: 6px 8px; text-align: left; }\n  td { padding: 5px 8px; border: 1px solid #ccc; vertical-align: top; }\n  tr:nth-child(even) { background-color: #f5f5f5; }\n  .meta { margin-bottom: 1em; }\n  .sev-CRITICAL { color: #8b0000; font-weight: bold; }\n  .sev-HIGH     { color: #cc4400; font-weight: bold; }\n  .sev-MEDIUM   { color: #cc8800; }\n  .sev-LOW      { color: #558800; }\n</style>\n</head>\n<body>\n<h2>IZ Gateway ECR Image Scan Report</h2>\n<div class=\"meta\">\n  <strong>Service:</strong> \($service | esc)<br>\n  <strong>Version:</strong> \($version | esc)<br>\n  <strong>Scan Date:</strong> \($scan_date | esc)<br>\n  <strong>Total Findings:</strong> \(length)\n</div>",

if length == 0 then
  "<p><em>No findings reported.</em></p>"
else
  "<table>\n  <thead>\n    <tr>\n      <th>CVE ID</th>\n      <th>Severity</th>\n      <th>CVSS Score</th>\n      <th>CVE Date</th>\n      <th>Package Name</th>\n      <th>Installed Version</th>\n      <th>Fixed In</th>\n      <th>Description</th>\n    </tr>\n  </thead>\n  <tbody>",
  (.[] |
    "    <tr><td><a href=\"https://nvd.nist.gov/vuln/detail/\(.cveId | esc)\">\(.cveId | esc)</a></td><td class=\"sev-\(.severity | esc)\">\(.severity | esc)</td><td>\(if .score < 0 then "" else .score | tostring end)</td><td>\(.cveDate | esc)</td><td>\(.pkgName | esc)</td><td>\(.installed | esc)</td><td>\(if .fixedIn == "" then "<em>None</em>" else .fixedIn | esc end)</td><td>\(.description | esc)</td></tr>"
  ),
  "  </tbody>\n</table>"
end,
"</body>\n</html>"
