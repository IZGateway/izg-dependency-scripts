## 1. Shared workflows

- [x] 1.1 Create `.github/workflows/maven-security-updates.yml` (`workflow_call`) from the tested izgw-transform workflow, with repository-specific values as inputs (design D1, D6, D8)
- [x] 1.2 Commit every changed tracked file through the Git Data API so the commit is signed (D4)
- [x] 1.3 Keep the `watch-pr-build` job, with `ci-workflow` and `max-build-reruns` inputs (D7)
- [x] 1.4 Create `.github/workflows/auto-merge-security-update.yml` (`workflow_call`) with the provenance and content checks, expecting `web-flow` as committer (D4, D5)
- [x] 1.5 Pass all `${{ }}` values into scripts through `env:`, never inline
- [x] 1.6 `actionlint` with shellcheck passes locally on all workflows

## 1b. Composite actions (design D1, D1a)

- [x] 1b.1 `setup-izg-maven`: JDK, Maven, `settings.xml` for `maven-servers`; token as input, fails when empty
- [x] 1b.2 `maven-patch-updates`: exclusions, patch updates, verify, PR description; output `has-changes`; no commit
- [x] 1b.3 `open-signed-pr`: signed commit through the Git Data API, PR, close older nightly PRs only for a nightly PR; outputs `pr-url`, `branch`, `head-sha`
- [x] 1b.4 `rerun-cancelled-build`: watch the PR's CI run and re-run it if cancelled; output `conclusion`
- [x] 1b.5 `auto-merge-bot-pr`: eligibility check inside the action (fail closed), provenance, content, approve, merge
- [x] 1b.6 Rewrite both workflows as recipes calling the actions at `@v1`; workflow inputs, secrets and outputs unchanged, so callers do not change
- [x] 1b.7 `actionlint` clean on the workflows; shellcheck clean on every `run:` script in the actions
- [x] 1b.8 README: building-block actions section

## 2. Docs

- [x] 2.1 README sections for both workflows: inputs, secrets, caller permissions, what the calling repository needs, example callers

## 3. First consumer: izgw-transform (IGDD-2766)

- [x] 3.1 Replace izgw-transform `security-updates.yml` with a thin caller pointing at `@IGDD-2766`
- [x] 3.2 Replace the auto-merge job in izgw-transform `maven.yml` with a `uses:` job pointing at `@IGDD-2766`
- [x] 3.3 Pre-merge test of the workflows BEFORE the composite-action restructure (section 1b): bot PR opened with a verified commit, CI passes, provenance and content checks pass, approved and merged; then reverted (passed 2026-11-23: izgw-transform PR #301, approved by github-actions and merged by izg-dependency-bot)
- [ ] 3.4 Re-test after the restructure. Temporarily point the action refs in both workflows at `@IGDD-2766`, and the izgw-transform callers at `@IGDD-2766`; run the same pre-merge test; then revert both
- [ ] 3.5 Merge this change with label `bump:minor`, confirm the `v1` tag moved (izgw-transform callers already point at `@v1`), and re-run izgw-transform PR #294's build

## 4. Follow-ups (not in this change)

- [ ] 4.1 izgw-core (IGDD-2764, PR #117), izgw-hub (IGDD-2765) and v2tofhir (IGDD-2763) adopt the shared workflows
- [ ] 4.2 Report nightly failures with `report-ci-failure`
- [ ] 4.3 Consider moving the patch-only `versions-maven-plugin` default into izgw-bom
- [ ] 4.4 IGDD-2969: reuse `auto-merge-bot-pr`, `open-signed-pr` and `rerun-cancelled-build` (or `auto-merge-security-update.yml`) for the npm repositories
- [ ] 4.5 Replace the hand-written `settings.xml` step in each Java repository's `maven.yml` and `release.yml` with `setup-izg-maven`
