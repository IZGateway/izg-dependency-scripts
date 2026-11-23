## 1. Shared workflows

- [x] 1.1 Create `.github/workflows/maven-security-updates.yml` (`workflow_call`) from the tested izgw-transform workflow, with repository-specific values as inputs (design D1, D6, D8)
- [x] 1.2 Commit every changed tracked file through the Git Data API so the commit is signed (D4)
- [x] 1.3 Keep the `watch-pr-build` job, with `ci-workflow` and `max-build-reruns` inputs (D7)
- [x] 1.4 Create `.github/workflows/auto-merge-security-update.yml` (`workflow_call`) with the provenance and content checks, expecting `web-flow` as committer (D4, D5)
- [x] 1.5 Pass all `${{ }}` values into scripts through `env:`, never inline
- [x] 1.6 `actionlint` with shellcheck passes locally on all workflows

## 2. Docs

- [x] 2.1 README sections for both workflows: inputs, secrets, caller permissions, what the calling repository needs, example callers

## 3. First consumer: izgw-transform (IGDD-2766)

- [ ] 3.1 Replace izgw-transform `security-updates.yml` with a thin caller pointing at `@IGDD-2766`
- [ ] 3.2 Replace the auto-merge job in izgw-transform `maven.yml` with a `uses:` job pointing at `@IGDD-2766`
- [ ] 3.3 Pre-merge test (temporary push trigger, bot PR into the izgw-transform feature branch): bot PR opened with a verified commit, CI passes, provenance and content checks pass, approved and merged; then revert the temporary commit and the bot's merge
- [ ] 3.4 Merge this change with label `bump:minor`, confirm the `v1` tag moved, and switch the izgw-transform callers to `@v1`

## 4. Follow-ups (not in this change)

- [ ] 4.1 izgw-core (IGDD-2764, PR #117), izgw-hub (IGDD-2765) and v2tofhir (IGDD-2763) adopt the shared workflows
- [ ] 4.2 Report nightly failures with `report-ci-failure`
- [ ] 4.3 Consider moving the patch-only `versions-maven-plugin` default into izgw-bom
- [ ] 4.4 IGDD-2969: reuse `auto-merge-security-update.yml` for the npm repositories
