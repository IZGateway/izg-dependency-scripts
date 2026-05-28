# Spec: failure-notification

## Purpose

Creates an IGDD TODO Jira ticket when a security update workflow fails — either
before merge (required checks fail on the PR) or after merge (build, deploy, or test
fails on the default branch after the PR is merged).

## Requirements

### Requirement: Pre-Merge Failure Ticket

GIVEN a security update PR has been identified by the `auto-merge-workflow`,<br>
WHEN one or more required status checks report `failure` or `cancelled`,<br>
THEN a Jira ticket is created in the IGDD project with:

- **Issue type:** TODO
- **Summary:** `[AUTO] Security update PR #<PR_NUMBER> failed pre-merge checks in <REPO>`
- **Description:** Includes:
  - Repository name and PR URL
  - List of failing check names and their log URLs
  - Link to the GitHub Actions workflow run
  - Context label: `pre-merge`

#### Scenario: Pre-merge check failure
WHEN a required check on a security update PR reports `failure`<br>
AND the `failure-notification` workflow is called with context `pre-merge`<br>
THEN a single IGDD TODO ticket is created with pre-merge context in the description.<br>
No merge attempt is made.

#### Scenario: Multiple checks fail
WHEN more than one required check fails on the same PR run<br>
THEN a single ticket is created listing all failing checks; duplicate tickets are not
created per failing check.

---

### Requirement: Post-Merge Failure Ticket

GIVEN a security update PR has been merged to the default branch,<br>
WHEN a `push` event triggers CI on the default branch<br>
AND the build, deploy, or test job fails,<br>
THEN a Jira ticket is created in the IGDD project with:

- **Issue type:** TODO
- **Summary:** `[AUTO] Post-merge failure on <BRANCH> after security update merge in <REPO>`
- **Description:** Includes:
  - Repository name and branch name
  - The merged PR number and title (from the merge commit message)
  - Failing job name and log URL
  - Link to the GitHub Actions workflow run
  - Context label: `post-merge`

#### Scenario: Post-merge build failure
WHEN the CI pipeline on the default branch fails after a security update merge<br>
AND the head commit message matches the security update commit pattern<br>
THEN a single IGDD TODO ticket is created with post-merge context.

#### Scenario: Post-merge failure on non-security update commit
WHEN the CI pipeline on the default branch fails<br>
AND the head commit is NOT a security update merge (pattern: `chore(deps): security
and dependency updates`)<br>
THEN no ticket is created by this workflow; the failure is handled by normal CI
notification channels.

---

### Requirement: Workflow Interface

The `failure-notification` capability is implemented as a reusable `workflow_call`
workflow (not a composite action) so it can be invoked from both the
`auto-merge-security-updates` workflow and a separate post-merge push trigger.

Inputs:

| Input | Type | Required | Description |
|---|---|---|---|
| `context` | string (`pre-merge` \| `post-merge`) | yes | Identifies when the failure occurred |
| `repository` | string | yes | Full `owner/repo` name of the failing project |
| `run-url` | string | yes | URL of the failing workflow run |
| `pr-number` | string | no | PR number (pre-merge only) |
| `pr-url` | string | no | PR URL (pre-merge only) |
| `failing-checks` | string | no | Comma-separated list of failing check names (pre-merge) |
| `branch` | string | no | Default branch name (post-merge only) |
| `merged-pr-title` | string | no | Title of the merged PR (post-merge only) |
| `failing-job` | string | no | Failing job name (post-merge only) |

Required secrets (passed from caller):
- `JIRA_URL` — Jira instance base URL.
- `JIRA_USER` — Jira account email for API authentication.
- `JIRA_API_TOKEN` — Jira API token.

#### Scenario: Called with pre-merge context
WHEN `context` is `pre-merge`<br>
AND `pr-number`, `pr-url`, and `failing-checks` are supplied<br>
THEN the ticket summary and description use pre-merge language and include PR details.

#### Scenario: Called with post-merge context
WHEN `context` is `post-merge`<br>
AND `branch`, `merged-pr-title`, and `failing-job` are supplied<br>
THEN the ticket summary and description use post-merge language and include branch and job details.

#### Scenario: Jira API call fails
WHEN the `jira-create-issue` action fails (network error, bad credentials, etc.)<br>
THEN the failure-notification workflow logs the error and exits with a non-zero status;<br>
it does NOT silently swallow the error, so the calling workflow's run is marked as failed.
