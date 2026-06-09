# Design: Fix `ecr-scan-report.sh` argv overflow

## Context

`.github/scripts/ecr-scan-report.sh` is invoked by the reusable workflow
`.github/workflows/ecr-scan-report.yml` (pinned by consumers as `@v1`). Its job is to:
1. Paginate `aws inspector2 list-findings` for a specific ECR repo + image tag.
2. Filter findings to those with `vendorCreatedAt <= --release-date`.
3. Emit three CDC-named files: `${DATE_PREFIX}_${PKG}_v${VERSION}_InspectorScan.{json,csv,html}`.

The current implementation accumulates findings across pagination using a shell
variable and re-passes the accumulator on each iteration:

```bash
# ecr-scan-report.sh lines 76-98 (paraphrased)
FINDINGS_ALL="[]"
NEXT_TOKEN=""
while true; do
  PAGE=$(aws inspector2 list-findings ... --output json)
  PAGE_FINDINGS=$(echo "$PAGE" | jq '.findings')
  FINDINGS_ALL=$(jq -n --argjson a "$FINDINGS_ALL" --argjson b "$PAGE_FINDINGS" '$a + $b')   # <-- line 94
  NEXT_TOKEN=$(echo "$PAGE" | jq -r '.nextToken // empty')
  [[ -z "$NEXT_TOKEN" ]] && break
done
```

Line 94 passes the entire accumulated findings JSON to `jq` as a `--argjson` argument.
`--argjson` values go into the spawned child's `argv`, which is bounded by the kernel's
`ARG_MAX` (typically 128 KB–2 MB). For high-finding images, this overflows partway
through pagination and `execve()` returns `E2BIG`. Bash reports exit 126.

Confirmed reproducer: `izg-transformation-ui:0.16.0` in the dev account
(`357442695278`, profile `cdc`). Failing run on record:
`https://github.com/IZGateway/izg-transformation-ui/actions/runs/26912695910`.

Constraints:
- Must preserve the CLI flag interface (`--repo`, `--tag`, `--pkg`, `--release-date`,
  `--out-dir`). Consumers and the reusable workflow's job step depend on it verbatim.
- Must preserve the CDC output naming convention.
- Must keep `set -euo pipefail` so failures propagate.
- No new runtime dependencies — GitHub Actions runners and developer workstations are
  expected to have `bash`, `jq`, `aws`, `mktemp`, and `trap` (all POSIX or near-POSIX).

Stakeholders: every IZGateway consumer of `ecr-scan-report.yml@v1`. The blocking
consumer today is `izg-transformation-ui`'s release workflow.

## Goals / Non-Goals

**Goals:**
- Eliminate the argv overflow at line 94 by keeping findings out of any spawned process's
  argv. Findings flow through file I/O (and, where convenient, stdin) only.
- Bound per-pagination memory and disk usage to one page (≈100 findings × tens of KB).
- Keep the diff scoped to `ecr-scan-report.sh`; no changes to the reusable workflow YAML,
  the jq helper, the README, or consumer-side code.
- Preserve all behavior on the small-finding path: same outputs, same naming, same exit
  codes, same release-date filter.

**Non-Goals:**
- Restructuring how the reusable workflow is invoked (e.g., switching from
  `workflow_call` to a composite action).
- Adding tests / fixtures to this repo. The reproducer is environmental (requires AWS
  Inspector2 access and a known-bad image); we verify against the live failing case.
- Touching `inspector2-scan-report.jq`. It already reads its input from a file
  (`${ARTIFACT_BASE}.json`) and is not in the failure path.
- Promoting any other spec from `cve-scan-action` to `openspec/specs/`. This CR creates
  one spec (`ecr-scan-report`) focused on the invariants this fix must preserve.
- Adding pagination/concurrency knobs. `--max-results 100` is fine; the issue is the
  accumulator, not the page size.

## Decisions

### D1: Stream each AWS page to its own file under a scratch directory

Replace the in-memory accumulator with a `mktemp -d` scratch directory. Each pagination
iteration writes its raw AWS response straight to `${SCRATCH}/page-NNNN.json`. After the
loop completes, one `jq -s 'map(.findings[]) | {findings: .}' "${SCRATCH}"/page-*.json`
call merges all pages into `${SCRATCH}/all-findings.json`. Findings never live in a
shell variable; argv carries only the small per-call flags and the (small) page filenames.

```bash
SCRATCH="$(mktemp -d -t izg-ecr-scan.XXXXXX)"
trap 'rm -rf "$SCRATCH"' EXIT

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

ALL_FINDINGS="$SCRATCH/all-findings.json"
jq -s 'map(.findings[]) | { findings: . }' "$SCRATCH"/page-*.json > "$ALL_FINDINGS"
```

**Why a directory, not one big appended file:** lets us use `jq -s` (slurp) over a glob,
which is idiomatic jq for "merge N JSON files into one structure." It also keeps each
page's raw AWS response intact for debugging if anything goes wrong — we can `ls
$SCRATCH/` mid-run (before the EXIT trap fires) and inspect individual pages.

**Why `printf '%s/page-%04d.json'` instead of `${SCRATCH}/page-${PAGE_NUM}.json`:** the
zero-padded name makes the glob sort lexicographically in pagination order, which means
the merged `all-findings.json` preserves AWS's return order. Not load-bearing for
correctness — Inspector2 doesn't promise any specific ordering — but it's nice for
diff'ing scan reports across runs.

**Alternatives considered:**
- *Append findings to one growing file with `jq -c '.findings[]' >> all.ndjson`,
  then convert to a JSON array at the end.* Works and uses less disk, but the page files
  are easier to inspect when debugging and disk is cheap on Actions runners. Rejected
  for ergonomics, not correctness.
- *Skip files entirely and chain `aws | jq | tee` into a single pipeline.* Doesn't
  work with pagination — `nextToken` requires capturing each response to extract the
  token before issuing the next call.
- *One-line surgery (`--slurpfile` instead of `--argjson`).* Works narrowly — keeps the
  shell variable but reads it from a file — but doesn't fix the underlying problem
  (the variable still grows linearly with findings and we'd be one refactor away from
  reintroducing the bug). Rejected.

### D2: Downstream consumers read the consolidated file

Once pagination produces `$ALL_FINDINGS`, every downstream `jq` call switches from
`echo "$VAR" | jq` to reading the file directly:

```bash
# Release-date filter — produces filtered.json
jq --arg cutoff "$RELEASE_DATE" '
  .findings |= map(select(
    (.packageVulnerabilityDetails.vendorCreatedAt // "9999-12-31T00:00:00Z") |
    split("T")[0] <= $cutoff
  ))
' "$ALL_FINDINGS" > "${ARTIFACT_BASE}.json"

# CSV — reads the already-filtered ARTIFACT_BASE.json
jq -r '... CSV pipeline ...' "${ARTIFACT_BASE}.json" > "${ARTIFACT_BASE}.csv"

# HTML — unchanged (already reads ARTIFACT_BASE.json)
jq -rf "${SCRIPT_DIR}/inspector2-scan-report.jq" --arg ... "${ARTIFACT_BASE}.json" > "${ARTIFACT_BASE}.html"
```

**Why filter into ARTIFACT_BASE.json directly:** today the script holds the filtered
findings in `FINDINGS_FILTERED` as a shell variable and then `echo "$FINDINGS_FILTERED"
| jq ...` three more times. That's three more re-serializations of a potentially-large
payload. Writing the filtered envelope to disk once and reading it three times is both
simpler and bounded.

**Why this is safe under the existing `echo` pattern:** `echo` is a bash builtin, so
its arguments never go through `execve()` and `ARG_MAX` doesn't apply. The `echo "$VAR"
| jq` form is *correct* today — it just isn't *uniform* with the file-based fix at
line 94. Switching all downstream sites to file input makes the no-argv-payload
invariant easier to audit and harder to regress.

### D3: Cleanup via `trap … EXIT`

The scratch directory is created once near the top of the script (after argument
parsing, before pagination) and removed unconditionally on exit:

```bash
SCRATCH="$(mktemp -d -t izg-ecr-scan.XXXXXX)"
# Scratch files (raw AWS page responses + merged findings) are removed on exit.
# To retain them for local debugging, comment out the trap line and re-run; the
# directory path is printed in the "Output base" log line near the top of the run.
trap 'rm -rf "$SCRATCH"' EXIT
```

`trap … EXIT` fires for normal exit, `set -e` aborts, and `exit N` calls. SIGKILL is
the only common signal that bypasses it; on GitHub Actions runners that's an
unrecoverable termination anyway.

**Why one scratch dir for the whole run, not per-page mktemp:** simpler cleanup, easier
to reason about, and the same scratch dir holds both the page-NNNN files and the merged
all-findings.json (and any future intermediates we add). Cost is one extra mkdir at
startup — negligible.

**No env-var override for the trap (e.g. `ECR_SCAN_KEEP_SCRATCH=1`).** Considered and
rejected: the only realistic debug need is local — GitHub Actions runners are ephemeral
and nothing in the workflow consumes scratch files anyway. A comment above the trap
(see code block above) gives the same discoverability with zero added API surface. If
someone hits a specific repeatable debug need we'll revisit.

### D4: `set -euo pipefail` stays

The script already starts with `set -euo pipefail`. We do not weaken this — any AWS
failure, jq failure, or unset variable still aborts immediately. The `trap … EXIT`
handles cleanup; `set -e` handles propagation.

**Implication:** if `aws inspector2 list-findings` returns non-zero on the *first* page,
the script exits before writing any page file, the trap removes the empty scratch dir,
and no output files exist. The reusable workflow's `continue-on-error: true` means the
job still completes (not block the release), but the caller's `upload-artifact` step
will warn that nothing is in `scan-reports/` — same observable behavior as today's
failure, just for a different reason.

### D5: No change to the `aws inspector2 list-findings` pagination logic

`--max-results 100` (max per the AWS API) and `nextToken` continuation are kept as-is.
The argv overflow is independent of page size — it's the accumulator that breaks.
Reducing `--max-results` would slow the script (more round trips) without addressing
the actual bug, and increasing it isn't possible (100 is the AWS limit).

### D6: Row dedup with key `(name, packageManager, version, fixedInVersion)`; filePaths joined in a new column

Verification against `izg-transformation-ui:0.16.0` (the same image whose argv overflow this CR fixes) surfaced a latent CSV/HTML behavior: each finding can have multiple `vulnerablePackages` entries that are identical except for `filePath`. Inspector2 reports the same Go vulnerability once per binary path (`/filebeat/filebeat`, `/usr/bin/filebeat`, `/metricbeat/metricbeat`, `/usr/bin/metricbeat`) because the same binary is shipped at multiple locations. The old CSV/HTML pipelines iterated `vulnerablePackages[]` and omitted `filePath` as a column, producing rows that looked like meaningless duplicates (150 rows for 39 findings on this image).

The fix is in two parts:

1. **Add `filePath` to the output as a column.** Reviewers can now see *which* installed locations are affected.
2. **Deduplicate on `(name, packageManager, version, fixedInVersion)`** within each finding and **join** the matching filePaths into the new column. For the live image this collapses 150 CSV rows down to 39 — one row per finding, since every multi-package finding on that image was a single Go package shipped at multiple paths.

The dedup key includes `packageManager` defensively. The current image has every finding's packages all from the same manager (mostly `GO`), so it doesn't affect the row count today. But future images might surface the same package name across ecosystems (e.g. a Go binary and an NPM dep sharing a name), and keeping the manager in the key preserves the right semantic split if that ever happens.

The jq implementation uses `group_by([.name, .packageManager, .version, .fixedInVersion])` — arrays sort lexically and equal arrays cluster, which is well-defined behavior. Inside each group, `.[0]` provides the representative tuple values and `map(.filePath // "") | unique | map(select(. != ""))` produces the joined paths cell.

**Why CSV joins paths with `", "` and HTML joins with `<br>`:** CSV cells get quoted by `@csv`, so a comma-separated list in one cell is unambiguous and reads fine in any spreadsheet. HTML cells get richer formatting via the `inspector2-scan-report.jq` helper — one path per line is more readable in a browser. Both formats individually HTML-escape (HTML side) the file paths before joining; CSV's `@csv` handles its own escaping.

**JSON output is unchanged.** The CSV/HTML deduplication is purely a presentation concern. The `${ARTIFACT_BASE}.json` envelope still mirrors the raw Inspector2 findings byte-for-byte (after the release-date filter). Downstream tools that want the raw shape (one entry per filePath) can keep using the JSON.

**Alternatives considered:**
- *One row per filePath (don't dedup).* Simplest. Rejected — the live experience proved this produces visually-confusing reports for CDC reviewers.
- *Dedup including filePath in the key.* No-op for the live image (filePath is the only varying field). Rejected — defeats the purpose.
- *Dedup across findings (not per-finding).* Tempting for a tighter report but loses per-finding context (severity, CVSS, date, description vary per finding). Rejected — keep dedup scope inside one finding.

### D7: No new spec promotion for other `cve-scan-action` outputs

The archived `cve-scan-action` CR introduced several capabilities: the OWASP composite
action, the CI/CD publish workflow, the release workflow, and `ecr-scan-report`. This
CR only promotes a spec for `ecr-scan-report` — the one we're modifying. The others
remain un-spec'd, consistent with their archived state. If a future CR needs to modify
the OWASP action or the CI workflow, that CR can promote those specs at that time.

## Risks / Trade-offs

- **[Risk]** Disk usage on the runner. Each page is up to ~100 findings × a few KB each
  = tens to low hundreds of KB. Even 50 pages (5,000 findings) is well under 10 MB.
  GitHub Actions runners have at least 14 GB free disk. No concern.
  → **Mitigation:** None needed. Documented for posterity.

- **[Risk]** The `jq -s 'map(.findings[]) | {findings: .}'` final merge loads all pages
  into jq memory simultaneously. For pathological finding counts (tens of thousands)
  this could spike memory.
  → **Mitigation:** Acceptable for IZGateway's foreseeable finding counts. If a service
  ever crosses ~10K findings we can switch the merge to a streaming approach
  (`--stream` mode or `--input-filename` line-by-line append), but that's premature.

- **[Risk]** The `trap … EXIT` fires before the script's last `echo "Done."` would —
  meaning scratch files are gone by the time a developer running locally sees the
  completion message. Cannot inspect pages post-run without manually disabling the trap.
  → **Mitigation:** A `TEST_OVERRIDES_DEBUG`-style env var (e.g., `ECR_SCAN_KEEP_SCRATCH=1`)
  could short-circuit the trap. Not adding now — easy to add later if anyone asks.

- **[Trade-off]** The fix doesn't address the equally-real risk that *future* edits to
  the script will reintroduce a "stuff a big variable into argv" pattern. The spec
  ([./specs/ecr-scan-report/spec.md](./specs/ecr-scan-report/spec.md)) captures the
  invariant ("findings SHALL NOT pass through argv"), but enforcement is by convention.
  Acceptable for now; revisit if it ever regresses.

## Migration Plan

1. Implement and merge the changes to `ecr-scan-report.sh` on this branch
   (`IGDD-2563_ecr-scan-jq-change`).
2. Local repro before opening the PR: with `AWS_PROFILE=cdc AWS_REGION=us-east-1`, run
   the script against `izg-transformation-ui:0.16.0` (per the handoff doc's verification
   recipe). Confirm exit 0 and that `scan-reports/20260604_izgw-transf-ui_v0.16.0_InspectorScan.{json,csv,html}`
   are non-empty and well-formed.
3. Sanity-check a low-finding image to confirm no regression on the small-finding path.
4. Open the PR with label `bump:patch`. On merge to `main`, `ci.yml` cuts the next
   patch release, publishes to GitHub Packages, and force-updates the `v1` floating tag.
5. After release, re-run `izg-transformation-ui`'s release workflow against `0.16.0`
   and confirm the scan report artifact is real and non-empty.

**Rollback:** Consumers can pin to the previous specific version (e.g.
`@v1.0.5`) to revert. The `v1` floating tag would still point at the broken commit
until it gets re-pointed at a known-good earlier ref, but in practice the affected
window is the time between this fix's merge and a hypothetical revert — minutes if
caught quickly.

## Open Questions

(None. Two questions were considered during design and resolved:

- *Keep individual page files beyond debugging?* No — AWS Inspector2 guarantees no
  cross-page duplicates, so per-page identity has no semantic value after the merge.
  Page files are throwaway intermediates.
- *Add an `ECR_SCAN_KEEP_SCRATCH=1` env var to retain scratch on exit?* No — see D3.
  A comment above the trap gives the same discoverability with no added API surface.)
