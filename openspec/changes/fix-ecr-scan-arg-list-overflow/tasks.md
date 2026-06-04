## 1. Scratch directory infrastructure

- [ ] 1.1 Add `SCRATCH="$(mktemp -d -t izg-ecr-scan.XXXXXX)"` after argument parsing and required-flag validation, before the "Derive names" block
- [ ] 1.2 Add `trap 'rm -rf "$SCRATCH"' EXIT` immediately after the scratch dir is created, with the documented "comment out to retain for local debugging" comment above it (per design D3)
- [ ] 1.3 Log the scratch path alongside the other "Output base / ECR repo / Image tag" lines so it shows up in failing run logs and locally
- [ ] 1.4 Confirm by inspection that no other code paths in the script create their own temp files (e.g., via `mktemp` elsewhere)

## 2. Pagination loop rewrite

- [ ] 2.1 Replace the existing `FINDINGS_ALL="[]"` / `NEXT_TOKEN=""` initialization with `PAGE_NUM=0` / `NEXT_TOKEN=""`
- [ ] 2.2 Inside the `while true` loop, compute `PAGE_FILE=$(printf '%s/page-%04d.json' "$SCRATCH" "$PAGE_NUM")` for the current iteration
- [ ] 2.3 Pipe the AWS CLI's `--output json` directly to `"$PAGE_FILE"` instead of capturing into a `PAGE` shell variable; preserve the `--next-token` branch
- [ ] 2.4 Extract `NEXT_TOKEN` by reading from the page file: `NEXT_TOKEN=$(jq -r '.nextToken // empty' "$PAGE_FILE")`
- [ ] 2.5 Increment `PAGE_NUM` and break on empty `NEXT_TOKEN`
- [ ] 2.6 Remove the offending line 94 entirely (`FINDINGS_ALL=$(jq -n --argjson a "$FINDINGS_ALL" --argjson b "$PAGE_FINDINGS" '$a + $b')`) along with the now-unused `PAGE_FINDINGS` capture
- [ ] 2.7 After the loop, add a merge step: `ALL_FINDINGS="$SCRATCH/all-findings.json"` then `jq -s 'map(.findings[]) | { findings: . }' "$SCRATCH"/page-*.json > "$ALL_FINDINGS"`
- [ ] 2.8 Replace the existing "Total findings fetched" log line to read from the merged file: `jq '.findings | length' "$ALL_FINDINGS"`

## 3. Downstream `jq` consumer updates

- [ ] 3.1 Rewrite the release-date filter step to read `"$ALL_FINDINGS"` and write directly into `"${ARTIFACT_BASE}.json"` (the filter SHALL output `{ findings: [...] }`, not a bare array, so downstream consumers and the existing HTML helper continue to work)
- [ ] 3.2 Remove the `FINDINGS_FILTERED` shell variable entirely — every downstream step reads `"${ARTIFACT_BASE}.json"` directly
- [ ] 3.3 Update the "Findings after release-date filter" log line to read the count from the file: `jq '.findings | length' "${ARTIFACT_BASE}.json"`
- [ ] 3.4 Rewrite the CSV step to read `"${ARTIFACT_BASE}.json"` directly (replace `echo "$FINDINGS_FILTERED" | jq -r '...'` with `jq -r '...' "${ARTIFACT_BASE}.json"`); the inner CSV pipeline starts from `.findings[]` rather than `.[]`
- [ ] 3.5 Leave the HTML step alone — it already reads `"${ARTIFACT_BASE}.json"` via `jq -rf ... "${ARTIFACT_BASE}.json"`

## 4. Local verification

- [ ] 4.1 With `AWS_PROFILE=cdc AWS_REGION=us-east-1`, run the script against the documented reproducer: `--repo izg-transformation-ui --tag 0.16.0 --pkg izgw-transf-ui --release-date 2026-06-03 --out-dir scan-reports`. Confirm exit `0`, no `Argument list too long` error, and all three output files non-empty
- [ ] 4.2 Open the JSON output and confirm `.findings` is an array with the expected high count (sanity-check against the run that originally failed)
- [ ] 4.3 Open the HTML and confirm rows render with CVE IDs, severities, and descriptions
- [ ] 4.4 Open the CSV and confirm it has a header row plus one row per CVE/package pair
- [ ] 4.5 Re-run a second time and confirm the previous run's scratch dir no longer exists (cleanup verification): `ls -d /tmp/izg-ecr-scan.*` between runs should show only the in-progress one
- [ ] 4.6 Run against a known low-finding image (any `izg-*` ECR image with a small finding set will do) and confirm the small-finding path still produces correct output — no regression
- [ ] 4.7 Run against a tag that produces zero findings (e.g., a fresh image tag with no known CVEs) and confirm the script still writes all three output files (empty `findings: []` JSON, header-only CSV, "No findings reported." HTML) and exits `0`
- [ ] 4.8 Simulate an AWS failure (revoke or invalidate the AWS profile temporarily) and confirm the script exits non-zero, scratch dir is removed by the trap, and no partial output files are written

## 5. Release

- [ ] 5.1 Open a PR from `IGDD-2563_ecr-scan-jq-change` to `main` with label `bump:patch`. PR title and body should reference IGDD-2563 and the failing `izg-transformation-ui:0.16.0` run as the motivating reproducer
- [ ] 5.2 After merge, verify `ci.yml` cuts the next patch release (e.g., `1.0.5` → `1.0.6`), publishes to GitHub Packages, and the floating `@v1` tag advances to the new commit
- [ ] 5.3 Confirm with `git ls-remote --tags origin v1` that `v1` points at the fixed commit, not the previous broken one
- [ ] 5.4 Re-run `izg-transformation-ui`'s release / test scan workflow against `image-tag=0.16.0`. Confirm: OIDC → poll → report → artifact path is green end-to-end, and the `izgw-transf-ui_v0.16.0_InspectorScan` artifact is non-empty and well-formed (open the files; don't trust the green check alone)
- [ ] 5.5 Coordinate with the `izg-transformation-ui` team on cleanup of their temporary `test-ecr-scan.yml` workflow (out of scope here but mentioned in the handoff doc)
