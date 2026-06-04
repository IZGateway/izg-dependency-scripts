# Proposal: Fix `ecr-scan-report.sh` argv overflow on high-finding images

## Date
2026-06-04

## Status
Proposed

## Jira

[IGDD-2563](https://izgateway.atlassian.net/browse/IGDD-2563)

## User Stories

**As IZGateway operations staff**, I want the reusable `ecr-scan-report.yml@v1` workflow
to succeed against any ECR image regardless of how many Inspector2 findings it has, so that
release-time scan reports are produced consistently for every service — not just the ones
with small finding sets.

## Success Criteria

- **Given** an ECR image with a large number of Inspector2 findings (the documented
  reproducer is `izg-transformation-ui:0.16.0`),
  **When** the reusable workflow calls `ecr-scan-report.sh`,
  **Then** the script succeeds, exits 0, and writes a non-empty JSON + CSV + HTML triple
  to the output directory using the CDC naming convention.
- **Given** an ECR image with zero findings,
  **When** the script runs,
  **Then** it still produces the three output files (JSON envelope with empty findings array,
  CSV with header row only, HTML with "No findings reported." block) and exits 0 —
  matching today's behavior on the small-finding path.
- **Given** the AWS CLI returns a `nextToken` indicating more pages,
  **When** the script paginates,
  **Then** memory and argv usage stay bounded per page — there is no accumulator that grows
  linearly (or worse) with total findings.

## Background

The reusable workflow `.github/workflows/ecr-scan-report.yml` and its companion script
`.github/scripts/ecr-scan-report.sh` were introduced in the `cve-scan-action` CR
(merged earlier) and published as the `v1` floating tag. Consumers pin to
`IZGateway/izg-dependency-scripts/.github/workflows/ecr-scan-report.yml@v1` and call it
from their release workflows to produce CDC-named Inspector2 scan reports.

`izg-transformation-ui` is the first consumer to hit a release with enough findings to
break the script. Failing run on record:
`https://github.com/IZGateway/izg-transformation-ui/actions/runs/26912695910` — exit code
126 with `line 94: /usr/bin/jq: Argument list too long`. Until this fix lands and the
`v1` tag advances, every release of that service (and any future high-finding service)
will fail to produce a scan report.

A full handoff doc with reproduction steps and diagnostics is at
`/Users/moodya/Downloads/fix-jq-ecr-scan.md` (workstation-local; not checked in).

## Why

Line 94 of `ecr-scan-report.sh` accumulates Inspector2 findings across pagination using
the pattern:

```bash
FINDINGS_ALL=$(jq -n --argjson a "$FINDINGS_ALL" --argjson b "$PAGE_FINDINGS" '$a + $b')
```

This passes the entire accumulated findings JSON to `jq` as a `--argjson` *command-line
argument* on every iteration. `--argjson` values go into the child process's `argv`, which
is bounded by the kernel's `ARG_MAX` (typically 128 KB–2 MB depending on the system). For
high-finding images, the accumulator's serialized size exceeds `ARG_MAX` partway through
pagination, `execve()` returns `E2BIG`, and bash reports exit 126 ("command found but
could not be executed"). The downstream `upload-artifact` step then warns about an empty
`scan-reports/` directory.

The bug is structural — *any* approach that accumulates findings into a shell variable
and re-passes them as argv will eventually hit this ceiling. The fix needs to keep the
findings out of argv entirely.

Fixing now unblocks the release of `izg-transformation-ui 0.16.0` and protects every
future consumer of `ecr-scan-report.yml@v1` from the same failure mode.

## What Changes

- **Replace the in-memory pagination accumulator** in `ecr-scan-report.sh` with a
  page-to-file streaming pattern: each `aws inspector2 list-findings` call writes its raw
  JSON page to a numbered file in a scratch directory (under `mktemp -d`). The pagination
  loop no longer touches `jq`. After pagination completes, one final
  `jq -s 'map(.findings[]) | {findings: .}' page-*.json > all-findings.json` call merges
  all pages — reading from files, not argv.
- **Update downstream `jq` steps** (release-date filter, JSON/CSV/HTML emission) to read
  the consolidated `all-findings.json` file rather than `echo "$FINDINGS_ALL" | jq …`.
  The `echo` form happens to be safe under bash builtins, but switching to file input
  makes the no-argv-payload invariant uniform and easier to keep right in the future.
- **Add scratch-directory cleanup** via `trap … EXIT` so partial files don't leak when the
  script fails mid-run.
- **No change** to the script's CLI interface (`--repo`, `--tag`, `--pkg`,
  `--release-date`, `--out-dir`), the reusable workflow's inputs, or the output file
  naming convention.
- **No change** to `inspector2-scan-report.jq` — it already consumes the JSON envelope
  via file input and is not part of the bug.
- **Bump label**: `bump:patch` — bug fix with no behavior change for callers using
  small-finding images, no API change.

## Capabilities

### New Capabilities
- `ecr-scan-report`: The reusable workflow and its companion script that fetch
  Inspector2 findings for a released ECR image, filter to vulnerabilities known at
  release time, and emit CDC-named JSON/CSV/HTML scan reports. The capability was
  introduced (un-spec'd) in the archived `cve-scan-action` CR; this CR establishes
  the first formal spec for it, focused on the invariants the argv-overflow fix
  must preserve (input contract, output naming, finding-count independence,
  pagination-memory bound).

### Modified Capabilities
<!-- None. `cve-scan-action` introduced the implementation but did not promote a spec
     to openspec/specs/. This CR is creating the first spec for `ecr-scan-report`. -->

## Impact

**Code:**
- `.github/scripts/ecr-scan-report.sh` — rewrite of the pagination loop (lines ~76–98)
  and the downstream `jq` consumer sites (lines ~105, 115, 119, 145). Expected diff:
  ~30–50 lines net.
- No new external dependencies. Uses existing tools: `aws` CLI, `jq`, `mktemp`, `trap`.

**Behavior in consumer repos:**
- `izg-transformation-ui`'s release workflow will start producing a non-empty
  `izgw-transf-ui_v{version}_InspectorScan` artifact on every release, not just
  low-finding ones.
- Every other consumer of `ecr-scan-report.yml@v1` is protected from the same failure
  mode without needing any caller-side change.

**Performance:**
- Per-page memory and disk usage are bounded (one page = max 100 findings).
- Total disk usage scales linearly with finding count (each page ≈ tens to hundreds of KB
  of raw JSON, well within `mktemp` scratch budgets on GitHub Actions runners).
- Wall-clock time roughly unchanged — the bottleneck is the AWS API, not local jq work.

**Release coordination:**
- `bump:patch` label on the PR. On merge to `main`, `ci.yml` cuts the next patch release
  (e.g. `1.0.5` → `1.0.6`), publishes to GitHub Packages, and force-updates the `v1`
  floating tag to point at the new commit.
- Consumers pinned to `@v1` (the canonical pin for reusable workflows) pick up the fix
  on their next workflow run with no caller-side change.
- `izg-transformation-ui` should re-run its scan workflow against `0.16.0` after the `v1`
  tag advances to verify end-to-end.
