# Design: `report-ci-failure` composite action

## Context

Today, three nightly dependency workflows open a PR and auto-merge it once its checks pass:
- `izgw-bom` `dependency-updates.yml`, 07:00 UTC on weekdays
- `izg-configuration-console` `security-updates.yml`, 03:00 UTC daily
- `izg-transformation-ui` `security-updates.yml`, 03:15 UTC daily

The bot has merged the last several PRs in each repo with no human involved. When a run fails, the only signal is a red run in the Actions tab.

The first version of this design emailed the Opsgenie integration address, copying `izgw-performance-test`. The self-test on 2026-11-19 proved the email reached Jira, but a repeat created a second ticket (IGDD-3850, IGDD-3851) instead of a comment, the tickets were Tasks, and the body was mangled. The team then chose to call Jira directly (2026-11-20).

Existing Jira API usage in the org:
- The CC app creates change-request tickets with `JIRA_API_URL` (`https://izgateway.atlassian.net/rest/api/2`, per `iz-gateway-terraform`) and `JIRA_API_AUTH_BASE64`. The same values are CC repo-level GitHub secrets for its Playwright E2E.
- The CveRouter Lambda (`izgw-aws-lambda`) creates Vulnerability tickets in IGDD with components, as a non-person "API User", with credentials in AWS Secrets Manager (`izgw-cve-router/jira_credentials`).
- IGDD-2767 (open) plans to move CC's Jira credential out of GitHub secrets into AWS Secrets Manager.

IGDD facts, checked 2026-11-19:
- Components `BOM`, `Configuration Console` and `Transformation Console` exist with those exact names. `Build / Deploy` also exists, for CI/CD.
- The Bug issue type exists. Creating a Bug requires only project, issue type and summary. Reporter is not settable.
- Board 27, "IGDD Scrum", is the project's only scrum board.

Constraints:
- **Public callers.** The three calling repos are public, and so is this one, so anything in a workflow file is world-readable.
- **No secrets in composite actions.** A composite action cannot read `secrets.*`. `cve-scan` already handles this by taking secrets as inputs.
- **Dispatch needs the default branch.** `workflow_dispatch` only works for workflow files that exist on the default branch, `main`.
- **Releases.** Merging to `main` releases the repo: `ci.yml` publishes the npm package and force-moves the `v1` tag.

People involved:
- Keith, who asked for this ticket
- the team, who receive the tickets
- an org admin, who owns the secrets
- whoever owns the Jira account behind the credential

## Goals / Non-Goals

**Goals:**
- One implementation that any IZ Gateway workflow can call in about 8 lines.
- The same failure, in the same component, adds a comment to its open ticket. A different failure opens its own ticket.
- Tickets have the right type, components and labels, chosen by the caller with sensible defaults.
- Nothing in the action or its callers reveals a credential or log content.
- The whole path is proven by a self-test before any product repo depends on it.

**Non-Goals:**
- Deciding when a failure is worth reporting. That is the caller's `if:`.
- Moving tickets between statuses, adding watchers, or changing a ticket's fields on a repeat.
- Reading the credential from AWS Secrets Manager (IGDD-2767's direction). Possible later.
- E2E failure reporting (IGDD-2762) and the Java nightly workflows (IGDD-2763 to IGDD-2766). They will reuse the action later.

## Decisions

### D1. Composite action, not a reusable workflow or copied steps

The action runs as a step inside the failing job.

**Why:** it can see that job's environment, for example `PR_URL` written to `$GITHUB_ENV` and the BOM's `steps.<id>.outcome`, so callers need no job-output wiring. It also follows the `cve-scan` pattern.

**Alternatives:**
- **Reusable workflow** (`workflow_call` with `needs:` and `if: failure()`). For: `secrets: inherit`. Against: the failed job's environment has to be passed out through job outputs, which means extra wiring in every caller.
- **Copying the steps into each workflow.** Simplest, but there will be about nine copies eventually, and any drift between them breaks repeat detection.

### D2. Call the Jira REST API (version 2) directly

**Why:** the action controls repeat detection, the issue type, components, labels and formatting itself, instead of depending on Opsgenie configuration nobody on the team owns. Version 2 accepts a wiki-markup string as the description, which is simple to build in shell and renders cleanly. CC's existing Jira URL is already version 2.

**Alternatives:**
- **Email Opsgenie.** Built and tested first. It delivered, but repeats opened new tickets, tickets were Tasks, the body was mangled, and Opsgenie is being retired.
- **Version 3.** Requires the description and comments in Atlassian Document Format (nested JSON). More code for no gain here.

### D3. Summary is the key; a hashed label is the match

The summary is `IZG CI failure: <component> - <workflow> - <failure description>`. It contains no date, run ID or SHA. Newlines are replaced with spaces, and it is capped at 255 characters, Jira's summary limit.

The action labels the ticket `ci-failure-<first 12 hex of sha1(summary)>`, and searches with:

```
project = "<project-key>" AND labels = "ci-failure-<h>" AND statusCategory != Done ORDER BY created DESC
```

**Why a label:** JQL's `summary ~` is a fuzzy text search and cannot match a summary exactly. A label matches exactly, and hashing keeps it short and free of spaces. `statusCategory != Done` means a closed ticket is not reused: the next failure opens a new ticket, which is what the team asked for.

**Why the failed step defines "same failure":** two different errors in `Build application` share a ticket, which is what you want while that step stays broken.

**Alternative:** include a hash of the error output. Rejected, because it would need log content, which conflicts with the no-logs rule, and timestamps in error messages would defeat repeat detection.

### D4. Failure description: reason, then last failed step in this job, then `unknown step`

Callers can pass `reason` for soft failures, such as the BOM's "PR left open". Otherwise the action calls `GET /repos/{repo}/actions/runs/{run_id}/attempts/{attempt}/jobs` with the job's token. It picks the job whose `runner_name` equals `$RUNNER_NAME`, and takes the name of the **last** step with `conclusion == "failure"`.

**Why the last failed step:** CC's `Run tests` step is `continue-on-error`, and it currently always fails because of the known Jest problem. Taking the first failed step would name `Run tests` every night and merge unrelated failures into one ticket. After the step that actually stopped the job, the only steps that run are `if: failure()` steps such as log uploads, which succeed, and the report step itself, which is still running. So the last failed step is the one that stopped the job.

**Why match on runner name:** in a workflow with several jobs, another job's failure must not be reported as this job's.

**Fallback:** any API or `jq` error falls through to `unknown step`. The lookup must never prevent a report. The 2026-11-19 self-test confirmed detection works on a real runner.

### D5. The credential is an input, from org secrets

`jira-api-url` and `jira-auth` are required inputs. Callers pass `secrets.JIRA_API_URL` and `secrets.JIRA_API_AUTH_BASE64`.

**Why inputs:** composite actions cannot read secrets.

**Names:** the org admin created the org secrets as `JIRA_API_URL` and `JIRA_API_AUTH_BASE64` (2026-11-20), and the team chose to keep those names rather than separate `JIRA_CI_*` ones.

**Known override in CC:** CC already has repo-level secrets with the same two names, and a repo secret overrides an org secret of the same name. So CC's nightly reports use CC's own repo secrets, while the other repos use the org secrets. That is harmless while both hold CC's credential (the trial). If the org secrets move to another account, also delete or update CC's repo-level secrets, or CC keeps filing tickets as the old account.

**Which account:** the org secrets authenticate as "API User", the same non-person account the CveRouter Lambda uses (confirmed by the reporter of the 2026-11-20 self-test ticket IGDD-3856). CC's repo-level secrets may hold a different account; see the override note above.

**Empty inputs:** the action fails with a clear error before calling Jira.

### D6. Delivery with `curl` and `jq`

The action removes any trailing `/` and `/rest/api/<n>` from `jira-api-url` to get the site, then uses:
- `POST <site>/rest/api/2/search/jql` to find an open ticket with the label
- `POST <site>/rest/api/2/issue/<key>/comment` to comment on it
- `POST <site>/rest/api/2/issue` to create a ticket
- `GET <site>/rest/agile/1.0/board/<board-id>/sprint?state=active` when `sprint: active`. If more than one sprint is active, the one with the latest `startDate` is used: on 2026-11-20 board 27 still had Sprint 42 active after Sprint 43 started, and taking the first result put the self-test ticket IGDD-3857 in the old sprint.

Request bodies are built with `jq -n --arg`, never by string interpolation. Authentication is `Authorization: Basic <jira-auth>`; the header is never echoed. Each call records its HTTP status:
- A create or comment that does not return 2xx fails the step, showing the status and Jira's `errorMessages` and `errors`.
- A failed search emits a warning and falls through to create, so a report is never lost.
- A failed sprint lookup emits a warning and creates the ticket without a sprint.

Outputs `issue-key`, `issue-url` (`<site>/browse/<key>`) and `result` (`created` or `commented`) are written to `$GITHUB_OUTPUT`, and the run's step summary gets a link to the ticket.

### D7. Self-test workflow in this repo

`test-report-ci-failure.yml` runs on `workflow_dispatch`, with a choice input `component` that defaults to `BOM`. It runs three steps:
1. Check out the repo.
2. A step named `Simulated failure` that runs `exit 1`.
3. `uses: ./.github/actions/report-ci-failure` with `if: failure()`, and no `reason`, so that step detection is exercised. It passes the Jira secrets and otherwise uses the default ticket settings.

Because the workflow name contains "Test", the summary is distinct from every real ticket. Running it twice checks repeat detection; the second run waits at least a minute, because Jira's search index can lag a newly created ticket by several seconds. The run is red by design.

The job sets `permissions: contents: read, actions: read`.

Before merge, the self-test is run from the `IGDD-2768` branch through a temporary `push` trigger, committed separately and removed before the PR is opened.

### D8. Caller contract

Callers:
- add `actions: read` to `permissions:`
- add the step last
- gate it with `if: failure() && github.event_name == 'schedule'`, so a developer's manual runs do not file tickets
- pass `jira-api-url: ${{ secrets.JIRA_API_URL }}` and `jira-auth: ${{ secrets.JIRA_API_AUTH_BASE64 }}`
- pin the action to `@v1`

The BOM also reports its warning-only "PR left open for review" path. Its condition becomes `github.event_name == 'schedule' && (failure() || steps.left-open.outcome == 'success')`, with an explicit `reason`.

### D9. Configurable ticket fields

| Input | Default | Sent as |
|---|---|---|
| `project-key` | `IGDD` | `project.key` |
| `issue-type` | `Bug` | `issuetype.name` |
| `components` | the `component` input | `components[].name`, split on commas and trimmed |
| `labels` | `ci-failure` | `labels`, split on commas, plus the repeat-detection label |
| `priority` | empty | `priority.name`, only when set |
| `assignee-account-id` | empty | `assignee.accountId`, only when set |
| `epic-key` | empty | `parent.key`, only when set |
| `sprint` | `active` | `customfield_10020` (Sprint) set to the active sprint's numeric ID when `active` |
| `board-id` | `27` | board for the active-sprint lookup |
| `ai-use` | `NA` | `customfield_10619` ("AI Use", single select) as `{value: ...}`, only when set |

**Why these defaults:** Bug is what IGDD-2768 asks for. The repo's own component is what the team uses today. The active sprint is the default (user decision, 2026-11-20) so a nightly failure is visible on the sprint board straight away instead of waiting in the backlog; a caller can pass `sprint: none` to opt out. "AI Use" defaults to `NA` because IGDD's Bug workflow hides its Done transitions until that field is set: the 2026-11-20 self-test ticket IGDD-3856 could not be closed until it was set by hand.

**Why repeats never change fields:** a comment is the whole repeat behavior. Someone may have reassigned, re-prioritised or re-scheduled the ticket, and the action should not undo that.

Invalid values, such as an unknown component, are not checked by the action. Jira rejects them, and the step fails with Jira's message.

## Risks / Trade-offs

- **[The account may lack permission in IGDD]** → The first self-test run shows a 401 or 403 immediately. Fix the account's permissions or switch accounts; no code change.
- **[Two failures at the same moment]** → Both searches find nothing and two tickets are created. Very unlikely for nightly jobs; accepted.
- **[Jira's search index lags new tickets]** → A repeat within seconds of a create could miss the new ticket. Irrelevant for nightly runs; the self-test waits a minute before its second run.
- **[Renaming a step changes the key]** → The next failure after a rename opens a new ticket. Acceptable and rare.
- **[One credential shared across four repos]** → Anyone with write access to those repos could read it through a workflow. Use an account limited to IGDD, and move to a dedicated account (or AWS Secrets Manager, IGDD-2767) after the trial.
- **[Secrets not shared with a repo]** → The empty-input check fails loudly. Rollout lists the secret step before any caller PR.
- **[Step detection depends on `actions: read`]** → The fallback is `unknown step`. The report is still made, but every unknown-step failure in a component shares one ticket.
- **[Self-test files real tickets]** → Their summary names the "Test report-ci-failure" workflow, so they are easy to recognise. The person running it closes them.
- **[A floating `v1` tag means callers get changes immediately]** → Matches how `cve-scan` and `ecr-scan-report` are consumed. Callers that need exact reproducibility can pin to `@v1.x.y`.

## Migration Plan

1. Rework the action and self-test on branch `IGDD-2768`. The temporary push trigger stays for now.
2. An org admin creates `JIRA_API_URL` and `JIRA_API_AUTH_BASE64`, shared with this repo and the three calling repos.
3. Push to the branch; the self-test runs. Confirm one Bug with the expected summary, component and labels. Re-run after a minute; confirm a comment and no new ticket.
4. Remove the temporary trigger, then open a PR to `main` labelled `bump:minor`. The existing `validate.yml` actionlint job must pass.
5. Merge. `ci.yml` releases `v1.1.0` and moves `v1`. No workflow calls the action yet, so this is harmless.
6. Wire the callers in separate PRs: `izg-configuration-console`, `izg-transformation-ui`, `izgw-bom`.

**Rollback:**
- Remove the caller step, which is one revert per repo.
- If the action itself is broken, revert in this repo. The next release moves `v1` back to working code.

## Open Questions

- Which Jira account backs `JIRA_API_AUTH_BASE64`: CC's credential, or the CveRouter "API User"?
- Should tickets also carry the `Build / Deploy` component? (Callers can pass it through `components`.)
- Should the action later read the credential from AWS Secrets Manager, in line with IGDD-2767?
