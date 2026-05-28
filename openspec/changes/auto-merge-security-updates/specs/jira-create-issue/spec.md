# Spec: jira-create-issue

## Purpose

Reusable composite action that creates a Jira issue via the Jira REST API using `curl`.
This is the **canonical Jira integration pattern for all IZ Gateway GitHub Actions
workflows** — future CRs requiring Jira ticket creation MUST reuse or extend this
action rather than routing through email-to-helpdesk or any other workaround.

## Requirements

### Requirement: Action Interface

The action is implemented as a GitHub Actions composite action located at
`.github/actions/jira-create-issue/action.yml` in `izg-dependency-scripts`.

Inputs:

| Input | Type | Required | Default | Description |
|---|---|---|---|---|
| `jira-url` | string | yes | — | Jira instance base URL (e.g., `https://yourorg.atlassian.net`) |
| `jira-user` | string | yes | — | Jira account email for Basic Auth |
| `jira-api-token` | string | yes | — | Jira API token (passed as secret) |
| `project-key` | string | yes | — | Jira project key (e.g., `IGDD`) |
| `issue-type` | string | no | `Task` | Issue type name (e.g., `Task`, `Bug`, `TODO`) |
| `summary` | string | yes | — | Issue summary / title |
| `description` | string | yes | — | Issue description (plain text or Jira markup) |

Outputs:

| Output | Description |
|---|---|
| `issue-key` | The created Jira issue key (e.g., `IGDD-1234`) |
| `issue-url` | Full URL to the created issue |

#### Scenario: Action called with all required inputs
WHEN the action is called with valid `jira-url`, `jira-user`, `jira-api-token`,
`project-key`, `summary`, and `description`<br>
THEN a Jira issue is created and `issue-key` and `issue-url` outputs are set.

---

### Requirement: REST API Call

The action uses `curl` with Basic Auth to call the Jira REST API v3
`POST /rest/api/3/issue` endpoint.

- Authentication: `Authorization: Basic base64(jira-user:jira-api-token)`
- Content-Type: `application/json`
- The request body is constructed from the input values.
- The action must not echo the API token to the workflow log.

#### Scenario: API returns 201 Created
WHEN the Jira API responds with HTTP 201<br>
THEN the action extracts the `key` field from the response JSON and sets `issue-key`
and `issue-url` outputs accordingly; the action exits with status 0.

#### Scenario: API returns non-2xx
WHEN the Jira API responds with a non-2xx status code<br>
THEN the action logs the HTTP status and the response body (excluding auth headers),
and exits with a non-zero status so the calling workflow step fails visibly.

---

### Requirement: Secret Handling

The `jira-api-token` input MUST be marked `secret: true` in the composite action
definition so the value is masked in workflow logs.

All `curl` commands must use environment variables for credentials, not inline shell
substitution, to ensure GitHub's secret masking is applied.

#### Scenario: Token appears in log
WHEN the `jira-api-token` input is correctly declared as a secret<br>
THEN any accidental echo of the token value in any step output is replaced with `***`.

---

### Requirement: Consuming Project Secrets

Any consuming project that invokes `failure-notification` (which uses `jira-create-issue`)
must have the following repository secrets configured:

- `JIRA_URL` — Jira instance base URL
- `JIRA_USER` — Jira account email
- `JIRA_API_TOKEN` — Jira API token with permission to create issues in the target project

The `migration` spec covers secret creation as a migration prerequisite.

#### Scenario: Secret missing in consuming repo
WHEN `JIRA_API_TOKEN` is not set in the consuming repository<br>
AND the `failure-notification` workflow is called<br>
THEN the `curl` call fails with an authentication error and the workflow step fails
visibly; the failure must not be silently ignored.

---

### Requirement: Reuse Pattern Documentation

The action MUST include a `README.md` in `.github/actions/jira-create-issue/`
documenting:

- How to call the action from a workflow step
- Required secrets and where to set them
- Example usage with `failure-notification`
- A note that this is the canonical IZ Gateway Jira integration pattern

#### Scenario: Future CR needs Jira ticket creation
WHEN a future CR author needs to create Jira tickets from GitHub Actions<br>
THEN they find the `jira-create-issue` action, read the README, and call the existing
action rather than writing a new `curl` block or email notification step.
