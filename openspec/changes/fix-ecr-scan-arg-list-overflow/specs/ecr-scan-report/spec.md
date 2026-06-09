# Spec: ecr-scan-report

Capability for the reusable workflow and companion shell script that fetch Inspector2
findings for a released ECR image, filter findings to those known at release time, and
emit CDC-named JSON / CSV / HTML scan report artifacts.

The capability was introduced (un-spec'd) in the archived `cve-scan-action` CR. This
spec is the first formal capture of its required behavior, written to lock in the
invariants the argv-overflow fix must preserve.

## ADDED Requirements

### Requirement: Output independence from finding count

The script SHALL produce its JSON, CSV, and HTML output files successfully regardless of
how many Inspector2 findings the target ECR image has. Specifically, the script SHALL
NOT pass the accumulated findings payload to any external process as a command-line
argument (argv), because argv is bounded by the kernel's `ARG_MAX` and large finding
sets exceed that bound.

The script SHALL hold per-page findings in files (or stdin) rather than in a shell
variable that grows across pagination iterations.

#### Scenario: High-finding image succeeds

- **WHEN** the script is invoked against an ECR image whose Inspector2 finding set
  exceeds the kernel `ARG_MAX` limit when serialized (the documented reproducer is
  `izg-transformation-ui:0.16.0`)
- **THEN** the script SHALL exit with code `0` and write a non-empty JSON, CSV, and HTML
  triple to the output directory using the CDC naming convention

#### Scenario: Pagination does not accumulate in argv

- **WHEN** the AWS CLI returns multiple pages of findings via `nextToken`
- **THEN** the script SHALL NOT call any external command (notably `jq`) with the
  accumulated findings as a command-line argument; per-page accumulation SHALL happen
  via file I/O

### Requirement: Zero-finding case still produces output files

The script SHALL produce all three output files even when Inspector2 returns zero
findings, preserving the convention that callers can always expect the output
directory to contain `${DATE_PREFIX}_${PKG}_v${VERSION}_InspectorScan.{json,csv,html}`.

#### Scenario: Zero findings produces empty but valid outputs

- **WHEN** Inspector2 returns no findings for the queried repo + tag combination
- **THEN** the script SHALL produce a JSON file containing `{"findings": []}`, a CSV
  file containing only the header row, and an HTML file containing a "No findings
  reported." block; the script SHALL exit `0`

### Requirement: CLI interface and output naming are stable

The script SHALL continue to accept the existing CLI flags exactly as defined: `--repo`,
`--tag`, `--pkg`, `--release-date`, and `--out-dir`. Output filenames SHALL follow the
CDC convention `${DATE_PREFIX}_${PKG}_v${VERSION}_InspectorScan.{json,csv,html}`, where
`DATE_PREFIX` is `${RELEASE_DATE}` with dashes removed and `VERSION` is `${TAG}` with
any `-RELEASE-*` suffix stripped.

#### Scenario: CLI flags unchanged

- **WHEN** the script is invoked with the existing flags
- **THEN** the script SHALL parse them exactly as before; no flag SHALL be renamed,
  removed, or change its meaning

#### Scenario: Output naming unchanged

- **WHEN** the script writes its three output files
- **THEN** the filenames SHALL match `${DATE_PREFIX}_${PKG}_v${VERSION}_InspectorScan.{json,csv,html}`,
  identical to today's convention

### Requirement: Findings are filtered to release date

The script SHALL filter the findings written to its output files to those whose
`packageVulnerabilityDetails.vendorCreatedAt` date (truncated to `YYYY-MM-DD`) is less
than or equal to the `--release-date` argument. Findings without a `vendorCreatedAt`
field SHALL be excluded from the filtered output by treating their date as far in the
future (`"9999-12-31T00:00:00Z"`), matching today's behavior.

#### Scenario: Findings newer than release date are excluded

- **WHEN** a finding's `vendorCreatedAt` is after the `--release-date` argument
- **THEN** the finding SHALL NOT appear in the JSON, CSV, or HTML output files

### Requirement: Scratch files are cleaned up

Any temporary files or directories created during the run SHALL be removed before the
script exits, including on error paths. The script SHALL NOT leave artifacts under
`mktemp` locations after a successful or failed run.

#### Scenario: Successful run leaves no scratch files

- **WHEN** the script completes successfully
- **THEN** all scratch directories created via `mktemp -d` (or equivalent) SHALL be
  removed before the script exits

#### Scenario: Failed run leaves no scratch files

- **WHEN** the script fails partway through (AWS error, jq error, signal)
- **THEN** any scratch directories created prior to the failure SHALL be removed via a
  `trap … EXIT` handler before the script's process terminates

### Requirement: CSV and HTML rows are deduplicated per package tuple

CSV and HTML output rows SHALL be emitted at the granularity of one row per
distinct `(name, packageManager, version, fixedInVersion)` tuple **within each
finding**, not one row per `vulnerablePackages` entry. When multiple
`vulnerablePackages` entries within the same finding share that tuple — for
example, the same Go binary installed at multiple filesystem locations — they
SHALL be collapsed into a single row whose "File Paths" cell contains all
matching `filePath` values joined for display.

CSV and HTML SHALL each include a "Package Manager" column (from
`packageManager`) and a "File Paths" column (joined `filePath` values). The
JSON output envelope SHALL NOT be reshaped — it still mirrors the raw
Inspector2 findings.

#### Scenario: Multiple file paths under one CVE collapse to one row

- **WHEN** an Inspector2 finding has multiple `vulnerablePackages` entries that
  share the same `(name, packageManager, version, fixedInVersion)` tuple and
  differ only by `filePath` (e.g., a Go binary installed at `/filebeat/filebeat`,
  `/metricbeat/metricbeat`, `/usr/bin/filebeat`, and `/usr/bin/metricbeat`)
- **THEN** the CSV and HTML SHALL emit exactly one row for that finding, with
  the "File Paths" column containing all four file paths joined for display

#### Scenario: Distinct package tuples produce distinct rows

- **WHEN** an Inspector2 finding has multiple `vulnerablePackages` entries that
  differ in any of `name`, `packageManager`, `version`, or `fixedInVersion`
- **THEN** the CSV and HTML SHALL emit a separate row for each distinct tuple,
  each with its own "File Paths" cell

#### Scenario: JSON envelope is unaffected

- **WHEN** the CSV/HTML deduplication runs
- **THEN** the `${ARTIFACT_BASE}.json` output SHALL retain the unmodified
  `vulnerablePackages` array exactly as Inspector2 returned it (no collapsing,
  no field removal)

### Requirement: Exit code reflects real outcome

The script SHALL exit non-zero on any genuine failure (AWS error, jq error, missing
required argument, malformed input). A successful run — including the zero-findings
case — SHALL exit `0`. The script SHALL NOT mask failures behind a `0` exit; in
particular, `set -euo pipefail` at the top of the script SHALL remain in place so a
failing `jq` or `aws` call propagates immediately rather than silently producing an
empty or partial report.

#### Scenario: AWS error propagates

- **WHEN** the AWS CLI returns a non-zero exit code (missing IAM permission, network
  failure, invalid region)
- **THEN** the script SHALL exit non-zero, and the calling workflow SHALL be able to
  detect the failure (subject to its own `continue-on-error` policy)

#### Scenario: Empty output is not silent success

- **WHEN** the script would produce a fully-empty output triple due to an internal
  error (not zero genuine findings)
- **THEN** the script SHALL exit non-zero rather than appearing green
