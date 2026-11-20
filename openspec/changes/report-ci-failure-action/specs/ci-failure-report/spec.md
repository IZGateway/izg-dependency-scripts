# Spec: ci-failure-report

This capability covers the shared composite action `.github/actions/report-ci-failure`. When a CI job fails, the action reports the failure as a Jira ticket through the Jira REST API: it adds a comment to an open ticket for the same failure, or creates a new ticket.

## ADDED Requirements

### Requirement: Caller decides when to report

The action SHALL report every time it is invoked. It SHALL NOT decide on its own whether the job failed, whether the run was scheduled, or whether a report is warranted. Callers SHALL control that with the step's `if:` condition, for example `failure() && github.event_name == 'schedule'`.

#### Scenario: Invoked on a failed scheduled run
- **WHEN** a caller's step runs the action with `if: failure() && github.event_name == 'schedule'`, and an earlier step in a scheduled run has failed
- **THEN** the action SHALL create or comment on exactly one ticket

#### Scenario: Invoked for a soft failure
- **WHEN** a caller invokes the action after a warning-only condition, such as the BOM's "PR left open for review", where no step has failed
- **THEN** the action SHALL still report, using the caller's `reason` input as the failure description

### Requirement: Required inputs

The action SHALL require these inputs:
- `component`: the component name used in the summary
- `jira-api-url`: the Jira REST base URL
- `jira-auth`: Base64 of `user:api-token`

The credential SHALL be supplied by the caller, normally from secrets. The action SHALL NOT contain a default or hardcoded credential. If any required input is empty, the action SHALL fail with an error naming the missing input and SHALL NOT call Jira.

#### Scenario: Credential missing
- **WHEN** the action is invoked with an empty `jira-auth` input, for example because the caller's secret is not shared with the repository
- **THEN** the action SHALL fail with an error stating that the Jira credential is missing, and SHALL NOT make any Jira API call

#### Scenario: URL given with an API version
- **WHEN** `jira-api-url` ends in `/rest/api/2`, `/rest/api/3` or nothing after the host
- **THEN** the action SHALL use the same site and call the version 2 REST API

### Requirement: Failure description

The action SHALL describe the failure using the first of these that is available:
1. The caller's `reason` input, if not empty.
2. The name of the last step whose conclusion is `failure` in the calling job, in the current run attempt, looked up through the GitHub Actions jobs API. The calling job is identified by its runner name. The last failed step is used rather than the first, so an earlier `continue-on-error` step that failed, such as a non-blocking Jest run, is not mistaken for the failure that stopped the job.
3. The literal text `unknown step`.

A failed or unauthorized lookup SHALL NOT stop the report.

#### Scenario: Reason supplied
- **WHEN** the caller passes `reason: "PR left open: CVE status unknown"`
- **THEN** the report SHALL use that text as the failure description, and SHALL NOT need the jobs API

#### Scenario: Failed step detected
- **WHEN** no `reason` is passed, the caller grants `actions: read`, and the step named `Build application` has failed
- **THEN** the report SHALL use `Build application` as the failure description

#### Scenario: Earlier non-blocking step also failed
- **WHEN** a `continue-on-error` step named `Run tests` failed, and a later step named `Build application` failed and stopped the job
- **THEN** the report SHALL use `Build application` as the failure description, not `Run tests`

#### Scenario: Lookup not possible
- **WHEN** no `reason` is passed and the jobs API call fails, for example because the token lacks `actions: read`
- **THEN** the report SHALL use `unknown step` as the failure description and SHALL still be made

### Requirement: Stable summary

The ticket summary SHALL be exactly `IZG CI failure: <component> - <workflow> - <failure description>`, where `<workflow>` is the calling workflow's name. The summary SHALL NOT contain a date, time, run ID, run number, attempt number or commit SHA, so the same component, workflow and failure description SHALL always produce byte-identical summaries. The summary SHALL be reduced to one line, and SHALL be no longer than 255 characters, Jira's summary limit.

#### Scenario: Same failure on two nights
- **WHEN** the `Configuration Console` `Security Updates` workflow fails at `Build application` on two different nights
- **THEN** both reports SHALL compute the identical summary `IZG CI failure: Configuration Console - Security Updates - Build application`

#### Scenario: Multi-line or very long description
- **WHEN** the failure description contains newlines, or would make the summary longer than 255 characters
- **THEN** the newlines SHALL be replaced with spaces, and the summary SHALL be truncated to 255 characters

### Requirement: Repeat detection

The action SHALL derive a repeat-detection label `ci-failure-<h>`, where `<h>` is the first 12 hexadecimal characters of the SHA-1 of the summary. Before creating a ticket, the action SHALL search the project for a ticket that carries that label and whose status category is not Done.
- If one is found, the action SHALL add a comment to the most recently created match and SHALL NOT create a ticket.
- If none is found, the action SHALL create a ticket that carries the label.

A comment SHALL NOT change any field of the existing ticket.

#### Scenario: First failure
- **WHEN** a failure is reported and no open ticket carries its label
- **THEN** the action SHALL create one ticket carrying the label, and set `result` to `created`

#### Scenario: Repeat while the ticket is open
- **WHEN** the same failure is reported again while its ticket's status category is not Done
- **THEN** the action SHALL add one comment to that ticket, SHALL NOT create a ticket, and SHALL set `result` to `commented`

#### Scenario: Repeat after the ticket is done
- **WHEN** the same failure is reported after its ticket has moved to a Done status
- **THEN** the action SHALL create a new ticket

#### Scenario: Different failure in the same component
- **WHEN** the same workflow fails at a different step
- **THEN** the summary and label SHALL differ, and the action SHALL create a separate ticket

### Requirement: Configurable ticket fields

When creating a ticket, the action SHALL set these fields from inputs:

| Input | Default | Field |
|---|---|---|
| `project-key` | `IGDD` | project |
| `issue-type` | `Bug` | issue type, by name |
| `components` | the `component` input | components, comma-separated names |
| `labels` | `ci-failure` | labels, comma-separated; the repeat-detection label is always added |
| `priority` | empty, so Jira's default | priority, by name |
| `assignee-account-id` | empty, so Jira's default | assignee |
| `epic-key` | empty, so none | parent |
| `sprint` | `none` | `none` leaves the ticket in the backlog; `active` adds it to the active sprint of `board-id` |
| `board-id` | `27` | board used for the active-sprint lookup |

An empty optional input SHALL leave that field out of the request. `sprint` SHALL accept only `none` or `active`; any other value SHALL fail the action before any Jira call.

#### Scenario: Defaults
- **WHEN** a caller passes only the required inputs with `component: Configuration Console`
- **THEN** the created ticket SHALL be a `Bug` in `IGDD`, with component `Configuration Console`, labels `ci-failure` and the repeat-detection label, and no sprint

#### Scenario: Multiple components
- **WHEN** a caller passes `components: "Configuration Console, Build / Deploy"`
- **THEN** the created ticket SHALL have both components

#### Scenario: Active sprint unavailable
- **WHEN** `sprint: active` is passed and the board has no active sprint, or the lookup fails
- **THEN** the action SHALL create the ticket without a sprint and emit a warning

### Requirement: Minimal content without logs

A new ticket's description, and a repeat comment, SHALL contain:
- the repository
- the workflow name
- the triggering event
- the ref
- the commit SHA
- a link to the workflow run
- the failure description
- the PR URL, when the caller passes one
- the UTC time of the report

They SHALL NOT include step logs, command output, environment dumps or secret values. Calling repositories are public, and the ticket only needs to point someone to the run.

#### Scenario: Content
- **WHEN** a report is made with `pr-url` set
- **THEN** the description or comment SHALL contain every field listed above, including the PR URL and a link of the form `<server>/<repo>/actions/runs/<run id>`

#### Scenario: No logs
- **WHEN** a report is made for any failure
- **THEN** the description or comment SHALL contain no text taken from step logs or command output

### Requirement: Outputs

The action SHALL set these outputs:
- `issue-key`: the key of the ticket created or commented on, for example `IGDD-1234`
- `issue-url`: the browse URL of that ticket
- `result`: `created` or `commented`

#### Scenario: Outputs after a create
- **WHEN** the action creates `IGDD-1234`
- **THEN** `issue-key` SHALL be `IGDD-1234`, `issue-url` SHALL end in `/browse/IGDD-1234`, and `result` SHALL be `created`

### Requirement: API failures are visible

If creating a ticket or adding a comment returns an error, the action's step SHALL fail, and the log SHALL show the HTTP status and Jira's error message. The log SHALL NOT show the credential. If the search for an existing ticket fails, the action SHALL emit a warning and create a ticket, so a report is never lost to a failed search.

#### Scenario: Credential rejected
- **WHEN** Jira answers the create request with 401 or 403
- **THEN** the action's step SHALL fail with that status in the error message

#### Scenario: Invalid field value
- **WHEN** a caller passes a component or issue type that does not exist in the project
- **THEN** the action's step SHALL fail, showing Jira's error message

#### Scenario: Search fails
- **WHEN** the search for an existing ticket returns an error
- **THEN** the action SHALL emit a warning and create a new ticket
