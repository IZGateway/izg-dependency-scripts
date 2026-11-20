## 1. Composite action (Jira route)

- [x] 1.1 Rework `.github/actions/report-ci-failure/action.yml` for Jira: update the description (what it does, the hashed-label repeat rule, credentials passed as inputs, never hardcode a credential), and remove the SMTP inputs and the `dawidd6/action-send-mail` step
- [x] 1.2 Declare inputs:
  - required: `component`, `jira-api-url`, `jira-auth`
  - unchanged: `reason`, `pr-url`, `github-token`
  - ticket fields with the defaults in design D9: `project-key`, `issue-type`, `components`, `labels`, `priority`, `assignee-account-id`, `epic-key`, `sprint`, `board-id`
- [x] 1.3 Declare outputs `issue-key`, `issue-url` and `result`
- [x] 1.4 Input check: fail with a clear `::error::` naming each empty required input, and when `sprint` is not `none` or `active`, before any Jira call
- [x] 1.5 Failure description (design D4): `reason`, else the last failed step in this job by runner name through the jobs API, else `unknown step`; inputs passed through `env:` only. (Carried over from the email version; verified on a real runner 2026-11-19.)
- [x] 1.6 Summary and label: one line, at most 255 characters, no date, run ID or SHA; label `ci-failure-` plus the first 12 hex characters of the summary's SHA-1
- [x] 1.7 Normalise `jira-api-url` to the site (strip a trailing `/` and any `/rest/api/<n>`), and add a helper that calls Jira with `curl`, the Basic auth header, a JSON body built with `jq -n`, and returns the HTTP status and body without ever echoing the header
- [x] 1.8 Search for an open ticket with the label (design D3); on a search error, warn and fall through to create
- [x] 1.9 If found: add a wiki-markup comment with the content fields from the spec, no logs, and set `result=commented`
- [x] 1.10 If not found: build the create body from the D9 inputs, leaving out empty optional fields; when `sprint: active`, look up the active sprint on `board-id` and add it, or warn and continue without it; create the ticket with a wiki-markup description and set `result=created`
- [x] 1.11 On a non-2xx create or comment, fail the step with the HTTP status and Jira's `errorMessages` / `errors`
- [x] 1.12 Write `issue-key`, `issue-url` and `result` to `$GITHUB_OUTPUT`, and a link to the ticket in `$GITHUB_STEP_SUMMARY`

## 2. Self-test workflow

- [x] 2.1 Create `.github/workflows/test-report-ci-failure.yml`:
  - triggered only by `workflow_dispatch`, with a `component` choice input (`BOM`, `Configuration Console`, `Transformation Console`; default `BOM`)
  - `permissions: contents: read, actions: read`
- [x] 2.2 Update the report step to pass `jira-api-url: ${{ secrets.JIRA_API_URL }}`, `jira-auth: ${{ secrets.JIRA_API_AUTH_BASE64 }}`, keeping `if: failure()` and no `reason`; remove the email secrets
- [x] 2.3 Update the header comment: the run is red by design, it files or comments on a real IGDD test ticket, the person running it closes the ticket, and a second run should wait at least a minute

## 3. Documentation

- [x] 3.1 Rewrite the `report-ci-failure` README section for the Jira route:
  - inputs and outputs tables
  - repeat detection: summary, hashed label, open versus Done
  - the caller requirements: `actions: read`, run it as the last step, `if: failure() && github.event_name == 'schedule'`, and the `JIRA_API_*` org secrets
  - an example caller step pinned to `@v1`
  - a note that step names matter, because they are part of the key
- [x] 3.2 Update `.github/copilot-instructions.md`: the action calls Jira directly; never hardcode a credential; never add a date, run ID or SHA to the summary; no logs in descriptions or comments

## 4. Validate (on the branch)

- [x] 4.1 Run actionlint (Docker `rhysd/actionlint`) and shellcheck on the action's scripts, and fix any findings
- [x] 4.2 Exercise the action's script locally with a fake `curl` and `gh`: create, comment, search error, sprint lookup, Jira error, and empty inputs
- [x] 4.3 Run `openspec validate report-ci-failure-action` and fix any findings
- [x] 4.4 Org admin: create org secrets `JIRA_API_URL` and `JIRA_API_AUTH_BASE64`, shared with `izg-dependency-scripts`, `izgw-bom`, `izg-configuration-console` and `izg-transformation-ui` (done 2026-11-20; CC's repo-level secrets of the same names override them in CC, see design D5)

## 5. End-to-end verification (on the branch, temporary push trigger)

- [x] 5.1 Push to `IGDD-2768`, and confirm:
  - one IGDD ticket is created, of type Bug
  - its summary is `IZG CI failure: BOM - Test report-ci-failure - Simulated failure`
  - it has component `BOM` and labels `ci-failure` plus the repeat-detection label
  - its description has the run link and no logs
  - the step outputs are `result=created` and the new key
- [x] 5.2 Wait at least a minute, re-run the same run, and confirm the existing ticket gets a comment, no second ticket is created, and `result=commented` (2026-11-20: run 44813122176 created IGDD-3856; attempt 2 commented on it)
- [x] 5.3 Close the test tickets: IGDD-3850 and IGDD-3851 (email route), IGDD-3856, IGDD-3857 and IGDD-3858 (Jira route) — all closed 2026-11-20
- [x] 5.4 After making `sprint: active` and `ai-use: NA` the defaults and closing IGDD-3856, push again and confirm the new ticket is in the active sprint of board 27 (IGDD Scrum) with "AI Use" set to NA; then close it (it should close without setting anything by hand) (2026-11-20: IGDD-3857 landed in the stale Sprint 42, fixed to pick the latest-started active sprint; IGDD-3858 landed in Sprint 43 with AI Use NA and closed straight from Open)
- [ ] 5.5 Record the self-test result on IGDD-2768

## 6. Release

- [x] 6.1 Remove the temporary push trigger from the self-test (a plain revert would conflict, because the file changed after that commit)
- [ ] 6.2 Open a PR to `main` labelled `bump:minor`, and make sure `validate.yml` passes
- [ ] 6.3 Merge, then confirm `ci.yml` released `v1.1.0` and moved the `v1` tag

## 7. Wire callers (separate PRs, branch `IGDD-2768` off `develop`)

- [ ] 7.1 `izg-configuration-console` `security-updates.yml`:
  - add `actions: read` to `permissions:`
  - add a last step using `report-ci-failure@v1`, with `component: Configuration Console`, the `JIRA_API_*` secrets, `pr-url: ${{ env.PR_URL }}`, and `if: failure() && github.event_name == 'schedule'`
- [ ] 7.2 `izg-transformation-ui` `security-updates.yml`: the same change, with `component: Transformation Console`. Pull `develop` first.
- [ ] 7.3 `izgw-bom` `dependency-updates.yml`:
  - add `actions: read`
  - add `id: left-open` to "Report PR left open for review"
  - add a last step with `component: BOM`, the `JIRA_API_*` secrets, condition `github.event_name == 'schedule' && (failure() || steps.left-open.outcome == 'success')`, and `reason` set only for the left-open case
  - rebase on `develop` first, because IGDD-2974 recently touched this file
- [ ] 7.4 In each repo, dispatch the workflow manually, and confirm the report step is skipped and the run is otherwise unchanged
- [ ] 7.5 Watch the next scheduled run in each repo: on green it should auto-merge with the report step skipped; on red it should file or comment on one ticket

## 8. Follow-ups

- [ ] 8.1 Comment on IGDD-2762 and IGDD-2763 to IGDD-2766 with the caller snippet, so the E2E and Java nightly workflows adopt the action
- [ ] 8.2 Ask the org admin to delete `JIRA_ALERT_EMAIL` once nothing uses it
- [ ] 8.3 Note on IGDD-2767 that CI ticketing uses the `JIRA_API_*` secrets, so moving to AWS Secrets Manager or a dedicated account covers it too
