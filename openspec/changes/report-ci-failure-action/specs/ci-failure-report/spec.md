# Spec: ci-failure-report

This capability covers the shared composite action `.github/actions/report-ci-failure`. When a CI job fails, the action reports the failure to the team's ticketing path by email: Opsgenie receives the email and creates the IGDD Jira ticket.

## ADDED Requirements

### Requirement: Caller decides when to report

The action SHALL send a report every time it is invoked. It SHALL NOT decide on its own whether the job failed, whether the run was scheduled, or whether a report is warranted. Callers SHALL control that with the step's `if:` condition, for example `failure() && github.event_name == 'schedule'`.

#### Scenario: Invoked on a failed scheduled run
- **WHEN** a caller's step runs the action with `if: failure() && github.event_name == 'schedule'`, and an earlier step in a scheduled run has failed
- **THEN** the action SHALL send one report email

#### Scenario: Invoked for a soft failure
- **WHEN** a caller invokes the action after a warning-only condition, such as the BOM's "PR left open for review", where no step has failed
- **THEN** the action SHALL still send one report email, using the caller's `reason` input as the failure description

### Requirement: Required inputs

The action SHALL require these inputs:
- `component`: the Jira component name
- `smtp-username` and `smtp-password`
- `to`: the alert address

The SMTP credentials and the alert address SHALL be supplied by the caller, normally from secrets. The action SHALL NOT contain a default or hardcoded alert address.

#### Scenario: Alert address missing
- **WHEN** the action is invoked with an empty `to` input, for example because the caller's secret is not available to the repository
- **THEN** the action SHALL fail with an error stating that the alert address is missing, and SHALL NOT attempt to send an email

#### Scenario: Alert address not present in source
- **WHEN** the action's source files are inspected
- **THEN** no Opsgenie or other inbound alert address SHALL appear in them

### Requirement: Failure description

The action SHALL describe the failure using the first of these that is available:
1. The caller's `reason` input, if not empty.
2. The name of the last step whose conclusion is `failure` in the calling job, in the current run attempt, looked up through the GitHub Actions jobs API. The calling job is identified by its runner name. The last failed step is used rather than the first, so an earlier `continue-on-error` step that failed, such as a non-blocking Jest run, is not mistaken for the failure that stopped the job.
3. The literal text `unknown step`.

A failed or unauthorized lookup SHALL NOT stop the report from being sent.

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
- **THEN** the report SHALL use `unknown step` as the failure description and SHALL still be sent

### Requirement: Stable subject as the repeat-detection key

The email subject SHALL be exactly `IZG CI failure: <component> - <workflow> - <failure description>`, where `<workflow>` is the calling workflow's name. The subject SHALL NOT contain a date, time, run ID, run number, attempt number or commit SHA. Opsgenie uses the subject to recognize a repeat of the same alert, so the same component, workflow and failure description SHALL always produce byte-identical subjects. The subject SHALL be reduced to one line, and SHALL be no longer than 130 characters, which is the length limit Opsgenie applies to an alert message.

#### Scenario: Same failure on two nights
- **WHEN** the `Configuration Console` `Security Updates` workflow fails at `Build application` on two different nights
- **THEN** both reports SHALL have the identical subject `IZG CI failure: Configuration Console - Security Updates - Build application`

#### Scenario: Different failure in the same component
- **WHEN** the same workflow fails at `Wait for PR checks, then merge if green` on a later night
- **THEN** that report's subject SHALL differ from the `Build application` subject

#### Scenario: Multi-line or very long description
- **WHEN** the failure description contains newlines, or would make the subject longer than 130 characters
- **THEN** the newlines SHALL be replaced with spaces, and the subject SHALL be truncated to 130 characters

### Requirement: Minimal body without log content

The email body SHALL contain:
- the repository
- the workflow name
- the triggering event
- the ref
- the commit SHA
- a link to the workflow run
- the failure description
- the PR URL, when the caller passes one
- the UTC time of the report
- the subject, labelled as the dedup key

The body SHALL NOT include step logs, command output, environment dumps or secret values. Calling repositories are public, and the ticket only needs to point someone to the run.

#### Scenario: Body contents
- **WHEN** a report is sent with `pr-url` set
- **THEN** the body SHALL contain every field listed above, including the PR URL and a link of the form `<server>/<repo>/actions/runs/<run id>`

#### Scenario: No logs in body
- **WHEN** a report is sent for any failure
- **THEN** the body SHALL contain no text taken from step logs or command output

### Requirement: Delivery failure is visible

The action SHALL send the email through the configured SMTP server, which defaults to the IZ Gateway SES relay. If the send fails, the action's step SHALL fail, so a broken reporter is visible in the run, rather than the action silently doing nothing.

#### Scenario: SMTP rejects credentials
- **WHEN** the SMTP server rejects the supplied credentials
- **THEN** the action's step SHALL fail
