# Proposal: `report-ci-failure` composite action

## Jira

[IGDD-2768](https://izgateway.atlassian.net/browse/IGDD-2768): Update security update scripts for auto-approval of nightly PRs

## Why

The nightly dependency-update workflows in `izgw-bom`, `izg-configuration-console` and `izg-transformation-ui` already open a PR and auto-merge it when its checks pass. When a run fails, nothing tells the team. The run turns red in the Actions tab and stays unnoticed until someone looks. IGDD-2768 asks for a bug ticket to be created on the IGDD board when a nightly dependency PR cannot merge.

The first version of this change emailed the Opsgenie integration address, the way `izgw-performance-test` does, so that Opsgenie would create the ticket. The end-to-end self-test on 2026-11-19 showed three problems with that route:
- A repeat of the same failure opened a second ticket (IGDD-3850, then IGDD-3851) instead of adding a comment. Repeat detection depends on Opsgenie configuration the team does not own.
- The tickets were created as Task, not Bug.
- The markdown body was mangled on its way through Opsgenie into Jira.

Opsgenie is also being retired by Atlassian. On 2026-11-20 the team decided to call the Jira REST API directly instead. That gives the action full control over repeat detection, the issue type, components, labels and formatting.

The same reporting is needed in at least six more places:
- the four Java nightly workflows (IGDD-2763 to IGDD-2766)
- the nightly E2E workflows (IGDD-2762)

So the logic belongs in one shared action rather than copied into each repo.

## What Changes

- **New composite action** `.github/actions/report-ci-failure/action.yml`. Called as a step in a failing job, it:
  - works out which step failed
  - builds a stable summary from the component, workflow and failed step, with no date or run number
  - derives a hidden repeat-detection label from that summary
  - searches the Jira project for an open ticket with that label
  - adds a comment to it if one exists, and otherwise creates a new ticket
  - writes a minimal description or comment with no log content
- **Configurable ticket fields**, each with a default: issue type (`Bug`), components (the `component` input), labels (`ci-failure`), sprint (the active sprint on board 27, or `none` for the backlog), and optionally priority, assignee and epic.
- **Credentials are passed in as inputs.** Composite actions cannot read `secrets.*`; `cve-scan` has the same constraint. The caller passes the Jira REST URL and a Base64 `user:token` value from org secrets.
- **No email.** The SMTP inputs and `dawidd6/action-send-mail` are removed.
- **New self-test workflow** `.github/workflows/test-report-ci-failure.yml`, run by `workflow_dispatch`. It forces a step to fail and calls the action, proving ticket creation and the repeat-comment behavior end to end.
- **README:** a new section under "Shared GitHub Actions" covering inputs, outputs, required caller permissions, and an example caller step.
- **Bump label:** `bump:minor`. This is a new capability; nothing existing changes.

## Capabilities

### New Capabilities
- `ci-failure-report`: reporting a failed CI job as an IGDD Jira ticket through the Jira REST API. Covers the input contract, the failed-step detection and its fallback, the stable summary, repeat detection by hashed label, configurable ticket fields, content limits on the description, outputs, and how API errors surface.

### Modified Capabilities
None. `override-evaluation` is the only spec in `openspec/specs/`, and this change does not touch it.

## Impact

**Code in this repo:**
- `.github/actions/report-ci-failure/action.yml` (new)
- `.github/workflows/test-report-ci-failure.yml` (new)
- `README.md` (new section)
- `.github/copilot-instructions.md` (list the new action next to `cve-scan`)

**Dependencies:**
- `curl`, `jq`, `sha1sum` and `gh`, all preinstalled on GitHub-hosted runners. No third-party action.

**Callers.** These are separate PRs in their own repos, tracked in `tasks.md`:
- `izg-configuration-console` and `izg-transformation-ui`: `security-updates.yml`
- `izgw-bom`: `dependency-updates.yml`, including its warning-only "PR left open for review" path
- Each caller adds `actions: read` to its `permissions:` block and a final step gated on `failure() && github.event_name == 'schedule'`.

**Organization settings (needs an org admin):**
- Org secrets `JIRA_API_URL` (for example `https://izgateway.atlassian.net/rest/api/2`) and `JIRA_API_AUTH_BASE64` (Base64 of `user:api-token`), shared with this repo and the three calling repos. CC's repo-level secrets of the same names override them in CC (design D5).
- Which Jira account backs them is still open: CC's existing credential for the trial, or the CveRouter Lambda's "API User", which already creates IGDD tickets. The account needs Browse, Create issues and Add comments in IGDD, plus Assign issues and Schedule issues if those settings are used.
- `JIRA_ALERT_EMAIL`, created for the email route, can be retired once nothing uses it.

**Out of scope:**
- Reading the Jira credential from AWS Secrets Manager. That is the direction of IGDD-2767 for CC's credential, and can be adopted later without changing the action's callers much.
- Moving tickets between statuses, adding watchers, or editing a ticket's fields on a repeat.
- Nightly E2E failure reporting (IGDD-2762). It will reuse this action.
- Moving `izgw-performance-test` onto this action.
