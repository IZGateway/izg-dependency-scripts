# Proposal: `report-ci-failure` composite action

## Jira

[IGDD-2768](https://izgateway.atlassian.net/browse/IGDD-2768): Update security update scripts for auto-approval of nightly PRs

## Why

The nightly dependency-update workflows in `izgw-bom`, `izg-configuration-console` and `izg-transformation-ui` open a PR and auto-merge it once its checks pass. When a run fails, nothing tells the team: the run turns red in the Actions tab and goes unnoticed until someone looks. IGDD-2768 asks for a bug ticket on the IGDD board when a nightly dependency PR can't merge.

An email-based first version could not tell a repeat failure from a new one, so the action calls the Jira REST API directly. That gives it full control over repeat detection, the issue type, components, labels and formatting.

Other nightly workflows, such as the E2E and Java builds, need the same reporting. So the logic belongs in one shared action, not copied into each repo.

## What Changes

- **New composite action** `.github/actions/report-ci-failure/action.yml`. Called as a step in a failing job, it:
  - works out which step failed
  - builds a stable summary from the component, workflow and failed step, with no date or run number
  - derives a hidden repeat-detection label from that summary
  - searches the Jira project for an open ticket with that label
  - adds a comment to it if one exists, and otherwise creates a ticket
  - writes a minimal description or comment, with no log content
- **Configurable ticket fields**, each with a default: issue type, components, labels, sprint and the "AI Use" field. Priority, assignee and epic are optional.
- **Credentials are passed in as inputs**, because composite actions cannot read `secrets.*`. `cve-scan` has the same constraint.
- **New self-test workflow** `.github/workflows/test-report-ci-failure.yml`, run by `workflow_dispatch`. It forces a step to fail and calls the action.
- **README:** a new section covering inputs, outputs, caller requirements, and an example caller step.
- **Bump label:** `bump:minor`. This is a new capability, and nothing existing changes.

## Capabilities

### New Capabilities
- `ci-failure-report`: reporting a failed CI job as a Jira ticket through the Jira REST API. Covers:
  - the input contract
  - failed-step detection and its fallback
  - the stable summary
  - repeat detection by hashed label
  - configurable ticket fields
  - content limits on the description
  - outputs
  - how API errors surface

### Modified Capabilities
None.

## Impact

- **Code in this repo:**
  - the new action and self-test workflow
  - a README section
  - `.github/copilot-instructions.md`
- **Dependencies:** `curl`, `jq`, `sha1sum` and `gh`, all preinstalled on GitHub-hosted runners. No third-party action.
- **Callers:** separate PRs in their own repos. Each adds `actions: read` to its permissions and a last step gated on scheduled runs that fail.
- **Organization settings:** org secrets `JIRA_API_URL` and `JIRA_API_AUTH_BASE64`, shared with this repo and the calling repos. The account behind them needs to browse, create issues and add comments in the project.

**Out of scope:** moving tickets between statuses, adding watchers, or editing a ticket's fields on a repeat.
