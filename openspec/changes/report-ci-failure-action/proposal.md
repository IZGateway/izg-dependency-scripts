# Proposal: `report-ci-failure` composite action

## Jira

[IGDD-2768](https://izgateway.atlassian.net/browse/IGDD-2768): Update security update scripts for auto-approval of nightly PRs

## Why

The nightly dependency-update workflows in `izgw-bom`, `izg-configuration-console` and `izg-transformation-ui` already open a PR and auto-merge it when its checks pass. When a run fails, nothing tells the team. The run turns red in the Actions tab and stays unnoticed until someone looks. IGDD-2768 asks for a bug ticket to be created on the IGDD board when a nightly dependency PR cannot merge.

The team decided to file tickets the same way `izgw-performance-test` already does: send an email to the Opsgenie integration address, which creates the Jira ticket. That avoids storing a Jira API credential in GitHub. The same reporting is needed in at least six more places:

- the four Java nightly workflows (IGDD-2763 to IGDD-2766)
- the nightly E2E workflows (IGDD-2762)

The subject line is what Opsgenie uses to recognize a repeat failure. It has to be identical everywhere, so the logic belongs in one shared action rather than copied into each repo.

## What Changes

- **New composite action** `.github/actions/report-ci-failure/action.yml`. Called as a step in a failing job, it:
  - works out which step failed
  - builds a stable subject from the component, workflow and failed step, with no date or run number, so a repeat of the same failure is recognized as the same alert
  - builds a minimal body with no log content
  - emails the Opsgenie address over the existing SES SMTP relay
- **Secrets are passed in as inputs.** Composite actions cannot read `secrets.*`; `cve-scan` has the same constraint. The caller passes the SMTP credentials and the Opsgenie address.
- **The Opsgenie address is never hardcoded.** All the calling repos are public, and a visible inbound address would let anyone create IGDD tickets.
- **New self-test workflow** `.github/workflows/test-report-ci-failure.yml`, run by `workflow_dispatch`. It forces a step to fail and calls the action, proving the email-to-Opsgenie-to-Jira path and the repeat-failure behavior end to end.
- **README:** a new section under "Shared GitHub Actions" covering inputs, required caller permissions, and an example caller step.
- **Bump label:** `bump:minor`. This is a new capability; nothing existing changes.

## Capabilities

### New Capabilities
- `ci-failure-report`: reporting a failed CI job to the team's ticketing path (Opsgenie by email, then Jira). Covers the input contract, the failed-step detection and its fallback, the subject-as-repeat-detection-key rule, the content limits on the body, and the requirement that the alert address is supplied by the caller rather than hardcoded.

### Modified Capabilities
None. `override-evaluation` is the only spec in `openspec/specs/`, and this change does not touch it.

## Impact

**Code in this repo:**
- `.github/actions/report-ci-failure/action.yml` (new)
- `.github/workflows/test-report-ci-failure.yml` (new)
- `README.md` (new section)
- `.github/copilot-instructions.md` (list the new action next to `cve-scan`)

**Dependencies:**
- `dawidd6/action-send-mail@v17`, the same action and version `izgw-performance-test` uses today
- `gh` and `jq`, which are preinstalled on GitHub-hosted runners

**Callers.** These are separate PRs in their own repos, tracked in `tasks.md`:
- `izg-configuration-console` and `izg-transformation-ui`: `security-updates.yml`
- `izgw-bom`: `dependency-updates.yml`, including its warning-only "PR left open for review" path
- Each caller adds `actions: read` to its `permissions:` block and a final step gated on `failure() && github.event_name == 'schedule'`.

**Organization settings (needs an org admin):**
- New org secret `JIRA_ALERT_EMAIL`
- `MAIL_USERNAME` and `MAIL_PASSWORD` must be available to the calling repos and to this repo, for the self-test
- Whether a repeat failure becomes a comment on the existing ticket rather than a new ticket depends on the Opsgenie email integration using the subject as the alert alias. The self-test checks this before any caller is wired up.

**Out of scope:**
- Nightly E2E failure reporting (IGDD-2762). It will reuse this action.
- Setting Jira fields beyond what Opsgenie sets.
- Moving `izgw-performance-test` onto this action.
