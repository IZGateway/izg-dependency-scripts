## 1. Composite action

- [x] 1.1 Create `.github/actions/report-ci-failure/action.yml` with `using: composite`, and a description that, like `cve-scan`, explains why the secrets are passed as inputs
- [x] 1.2 Declare inputs:
  - required: `component`, `smtp-username`, `smtp-password`, `to`
  - optional, empty by default: `reason`, `pr-url`
  - optional, defaulting to `${{ github.token }}`: `github-token`
  - optional, with the perf-test values as defaults: `server-address`, `server-port`, `from`
- [x] 1.3 Add a guard step that fails with a clear `::error::` when `to`, `smtp-username` or `smtp-password` is empty, before anything is sent (design D5)
- [x] 1.4 Add the failure-description step (design D4):
  - use `reason` if it is set
  - otherwise call the run-attempt jobs API through `gh api`, pick the job whose `runner_name` matches `$RUNNER_NAME`, and take the name of the last step with `conclusion == "failure"`
  - fall back to `unknown step` on any error
  - pass every input to the script through `env:`, never by interpolating it into the script text
- [x] 1.5 Build the subject `IZG CI failure: <component> - <workflow> - <description>`: replace newlines with spaces, cap it at 130 characters, and include no date, run ID or SHA (spec: stable subject)
- [x] 1.6 Build the markdown body with exactly the spec's field list and no log content, and write the subject and body out through `$GITHUB_OUTPUT` using a heredoc delimiter
- [x] 1.7 Send the email with `dawidd6/action-send-mail@v17`, using `secure: true` and `convert_markdown: true`, and the server, port and from inputs; let a send failure fail the step (design D6)

## 2. Self-test workflow

- [x] 2.1 Create `.github/workflows/test-report-ci-failure.yml`:
  - triggered only by `workflow_dispatch`, with a `component` choice input (`BOM`, `Configuration Console`, `Transformation Console`; default `BOM`)
  - `permissions: contents: read, actions: read`
- [x] 2.2 Add the steps:
  - checkout
  - a step named `Simulated failure` that runs `exit 1`
  - `uses: ./.github/actions/report-ci-failure` with `if: failure()` and no `reason`, passing `secrets.MAIL_USERNAME`, `secrets.MAIL_PASSWORD` and `secrets.JIRA_ALERT_EMAIL`
- [x] 2.3 Add a header comment saying the run is red by design and files a real test ticket, which the person running it closes

## 3. Documentation

- [x] 3.1 Add a `report-ci-failure` section to `README.md` under "Shared GitHub Actions", covering:
  - an inputs table
  - the caller requirements: `actions: read`, run it as the last step, and `if: failure() && github.event_name == 'schedule'`
  - an example caller step pinned to `@v1`
  - a note that the subject is the repeat-detection key, so step names matter
- [x] 3.2 List the new action next to `cve-scan` in `.github/copilot-instructions.md`, including the "no hardcoded alert address" rule

## 4. Validate and release

- [x] 4.1 Run actionlint locally on the new action and workflow, through Docker (`rhysd/actionlint`), and fix any findings
- [x] 4.2 Run `openspec validate report-ci-failure-action` and fix any findings
- [ ] 4.3 Open a PR to `main` labelled `bump:minor`, and make sure `validate.yml` passes
- [x] 4.4 Org admin: create the org secret `JIRA_ALERT_EMAIL`, and share it plus `MAIL_USERNAME` and `MAIL_PASSWORD` with `izg-dependency-scripts`, `izgw-bom`, `izg-configuration-console` and `izg-transformation-ui`
- [ ] 4.5 Merge, then confirm `ci.yml` released `v1.1.0` and moved the `v1` tag

## 5. End-to-end verification

- [ ] 5.1 Dispatch `test-report-ci-failure.yml` once, and confirm:
  - one IGDD ticket is created
  - its subject is `IZG CI failure: BOM - Test report-ci-failure - Simulated failure`
  - its body has the run link and no logs
- [ ] 5.2 Dispatch it again with the same input, and confirm the existing ticket gets a comment and no second ticket is created. If a second ticket appears, raise Opsgenie alias and comment configuration with its owner before going further.
- [ ] 5.3 Close the test ticket and record the result on IGDD-2768

## 6. Wire callers (separate PRs, branch `IGDD-2768` off `develop`)

- [ ] 6.1 `izg-configuration-console` `security-updates.yml`:
  - add `actions: read` to `permissions:`
  - add a last step using `report-ci-failure@v1`, with `component: Configuration Console`, `pr-url: ${{ env.PR_URL }}`, and `if: failure() && github.event_name == 'schedule'`
- [ ] 6.2 `izg-transformation-ui` `security-updates.yml`: the same change, with `component: Transformation Console`. Pull `develop` first.
- [ ] 6.3 `izgw-bom` `dependency-updates.yml`:
  - add `actions: read`
  - add `id: left-open` to "Report PR left open for review"
  - add a last step with `component: BOM`, condition `github.event_name == 'schedule' && (failure() || steps.left-open.outcome == 'success')`, and `reason` set only for the left-open case
  - rebase on `develop` first, because IGDD-2974 recently touched this file
- [ ] 6.4 In each repo, dispatch the workflow manually, and confirm the report step is skipped and the run is otherwise unchanged
- [ ] 6.5 Watch the next scheduled run in each repo: on green it should auto-merge with the report step skipped; on red it should file one ticket

## 7. Follow-ups

- [ ] 7.1 Comment on IGDD-2762 and IGDD-2763 to IGDD-2766 with the caller snippet, so the E2E and Java nightly workflows adopt the action
