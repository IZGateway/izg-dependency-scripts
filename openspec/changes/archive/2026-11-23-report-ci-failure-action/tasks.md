## 1. Composite action

- [x] 1.1 Write `.github/actions/report-ci-failure/action.yml`. Its description covers what it does, the hashed-label repeat rule, and that credentials are passed as inputs.
- [x] 1.2 Declare the inputs:
  - required: `component`, `jira-api-url`, `jira-auth`
  - optional: `reason`, `pr-url`, `github-token`
  - ticket fields with the defaults in design D9
- [x] 1.3 Declare the outputs `issue-key`, `issue-url` and `result`
- [x] 1.4 Input check, before any Jira call: fail with a clear error for each empty required input, and when `sprint` is not `none` or `active`
- [x] 1.5 Failure description (design D4): `reason`, else the last failed step in this job, else `unknown step`
- [x] 1.6 Summary and label: one line, at most 255 characters, no date, run ID or SHA. The label is `ci-failure-` plus the first 12 hex characters of the summary's SHA-1.
- [x] 1.7 Normalise `jira-api-url`, and add a `curl` helper:
  - JSON bodies built with `jq -n`
  - bounded timeouts
  - never echoes the Authorization header
- [x] 1.8 Search for an open ticket with the label; on a search error, warn and create
- [x] 1.9 If one is found, add a comment with the content fields from the spec and no logs
- [x] 1.10 If none is found, create a ticket from the D9 inputs:
  - leave out empty optional fields
  - look up the most recently started active sprint when `sprint: active`
- [x] 1.11 On a create or comment that doesn't return 2xx, fail with the HTTP status and Jira's error message
- [x] 1.12 Write the outputs, and a link to the ticket in the step summary

## 2. Self-test workflow

- [x] 2.1 Create `.github/workflows/test-report-ci-failure.yml`:
  - `workflow_dispatch` only, with a `component` choice input
  - `permissions: contents: read, actions: read`
- [x] 2.2 The report step passes the Jira secrets, with `if: failure()` and no `reason`
- [x] 2.3 Header comment: the run is red by design, it files a real test ticket that the runner closes, and a second run should wait a minute

## 3. Documentation

- [x] 3.1 README section:
  - inputs and outputs
  - how repeats are detected
  - caller requirements
  - an example caller step pinned to `@v1`
- [x] 3.2 Update `.github/copilot-instructions.md`

## 4. Validate

- [x] 4.1 actionlint and shellcheck pass
- [x] 4.2 Exercise the script locally with a fake `curl` and `gh`:
  - create, comment, search error
  - sprint lookup, Jira errors
  - timeouts, empty inputs
- [x] 4.3 `openspec validate report-ci-failure-action` passes
- [x] 4.4 Org secrets `JIRA_API_URL` and `JIRA_API_AUTH_BASE64` are shared with this repo and the calling repos

## 5. End-to-end verification

- [x] 5.1 The self-test creates one Bug with the expected summary, component and labels, a run link, and no logs
- [x] 5.2 Re-running it adds a comment to that ticket instead of creating a second one
- [x] 5.3 With the defaults, the ticket lands in the active sprint with "AI Use" set, and can be closed without hand edits
- [x] 5.4 Test tickets closed

## 6. Release

- [x] 6.1 Remove the temporary branch trigger from the self-test
- [x] 6.2 Open a PR to `main` labelled `bump:minor`; `validate.yml` passes
- [x] 6.3 Merge; `ci.yml` releases `v1.1.0` and moves the `v1` tag; the self-test passes from `main`

## 7. Callers

- [x] 7.1 Open the `izg-configuration-console` PR (`security-updates.yml` and `playwright-nightly.yml`)
- [x] 7.2 Open the `izg-transformation-ui` PR (`security-updates.yml` and `playwright-nightly.yml`)
- [x] 7.3 Open the `izgw-bom` PR (`dependency-updates.yml`, including the "PR left open for review" case)

## Remaining work (tracked on IGDD-2768)

- After each caller PR merges, run the workflow by hand and confirm the report step is skipped. Then watch its next scheduled run.
- Share the caller snippet with the owners of other nightly workflows that should adopt the action.
