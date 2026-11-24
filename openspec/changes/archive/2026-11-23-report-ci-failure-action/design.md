# Design: `report-ci-failure` composite action

## Context

Three nightly dependency workflows open a PR and auto-merge it once its checks pass:
- `izgw-bom` `dependency-updates.yml`
- `izg-configuration-console` `security-updates.yml`
- `izg-transformation-ui` `security-updates.yml`

When a run fails, the only signal is a red run in the Actions tab.

Constraints:
- **Public repos.** This repo and its callers are public, so anything in a workflow file is world-readable.
- **No secrets in composite actions.** A composite action cannot read `secrets.*`. `cve-scan` already handles this by taking secrets as inputs.
- **Dispatch needs the default branch.** `workflow_dispatch` only works for workflow files that exist on `main`.
- **Releases.** Merging to `main` releases the repo: `ci.yml` publishes the npm package and moves the `v1` tag.

## Goals / Non-Goals

**Goals:**
- One implementation that any IZ Gateway workflow can call in a few lines.
- The same failure adds a comment to its open ticket; a different failure opens its own ticket.
- Tickets get the right type, components and labels, chosen by the caller, with sensible defaults.
- Nothing in the action or its callers reveals a credential or log content.
- A self-test proves the whole path before any product repo depends on it.

**Non-Goals:**
- Deciding when a failure is worth reporting. That is the caller's `if:`.
- Moving tickets between statuses, adding watchers, or changing a ticket's fields on a repeat.

## Decisions

### D1. Composite action, not a reusable workflow or copied steps

The action runs as a step inside the failing job.

**Why:** it can see that job's environment, such as `PR_URL` in `$GITHUB_ENV` and `steps.<id>.outcome`, so callers need no job-output wiring. It also follows the `cve-scan` pattern.

**Alternatives:**
- **A reusable workflow:** the failed job's state would have to be passed out through job outputs, which means extra wiring in every caller.
- **Copying the steps into each workflow:** any drift between the copies breaks repeat detection.

### D2. Call the Jira REST API (version 2) directly

**Why:** the action controls repeat detection, the issue type, components, labels and formatting itself. Version 2 accepts a wiki-markup string as the description, which is simple to build in shell.

**Alternatives:**
- **Email-to-ticket:** couldn't detect repeats or set the issue type.
- **Version 3:** needs Atlassian Document Format (nested JSON), which is more code for no gain here.

### D3. The summary is the key; a hashed label is the match

The summary is `IZG CI failure: <component> - <workflow> - <failure description>`. It contains no date, run ID or SHA. It is reduced to one line and capped at 255 characters, Jira's limit.

The ticket is labelled `ci-failure-<first 12 hex of sha1(summary)>`, and the action searches with:

```
project = "<project-key>" AND labels = "ci-failure-<h>" AND statusCategory != Done ORDER BY created DESC
```

**Why a label:** JQL's `summary ~` is a fuzzy text search. A label matches exactly, and hashing keeps it short. `statusCategory != Done` means a closed ticket is not reused, so the next failure opens a new ticket.

**Alternative:** hashing the error output. Rejected: it needs log content, and timestamps in errors would defeat repeat detection.

### D4. Failure description: reason, then the last failed step, then `unknown step`

Callers can pass `reason` for soft failures and for failures they want grouped. Otherwise the action reads the run attempt's jobs through the GitHub API, picks the job whose `runner_name` equals `$RUNNER_NAME`, and takes the name of the **last** step with `conclusion == "failure"`.

**Why the last failed step:** an earlier `continue-on-error` step that failed, such as a non-blocking test step, must not be named in place of the step that stopped the job.

**Why match on runner name:** in a workflow with several jobs, another job's failure must not be reported as this job's.

**Fallback:** any API or `jq` error, or a lookup longer than 60 seconds, gives `unknown step`. The lookup must never prevent a report.

Step names are carried as JSON strings until the last one is picked, so a name with a line break keeps every line.

### D5. The credential is an input, from org secrets

`jira-api-url` and `jira-auth` are required inputs. Callers pass `secrets.JIRA_API_URL` and `secrets.JIRA_API_AUTH_BASE64`.

- **Why inputs:** composite actions cannot read secrets.
- **Empty inputs:** the action fails with a clear error before calling Jira.
- **Precedence:** a repository secret with the same name takes precedence over the org secret in that repository.

### D6. Delivery with `curl` and `jq`

The action strips any trailing `/` and `/rest/api/<n>` from `jira-api-url` to get the site. It then calls:
- `POST <site>/rest/api/2/search/jql` to find an open ticket with the label
- `POST <site>/rest/api/2/issue/<key>/comment` to comment on it
- `POST <site>/rest/api/2/issue` to create a ticket
- `GET <site>/rest/agile/1.0/board/<board-id>/sprint?state=active` when `sprint: active`. If more than one sprint is active, the one that started most recently is used.

Request bodies are built with `jq -n --arg`, never by string interpolation. The Authorization header is never echoed.

Error handling:
- A create or comment that doesn't return 2xx fails the step, showing the status and Jira's error message.
- A failed search warns and falls through to create, so a report is never lost.
- A failed sprint lookup warns and creates the ticket without a sprint.

Every Jira call uses `curl --connect-timeout 10 --max-time 30`. A timeout is treated like an unreachable Jira, so the fallbacks above still apply, and an unresponsive service can't hold the failed job.

The outputs `issue-key`, `issue-url` and `result` are written to `$GITHUB_OUTPUT`, and the run's step summary links the ticket.

### D7. Self-test workflow

`test-report-ci-failure.yml` runs on `workflow_dispatch`:
1. It checks out the repo.
2. A step named `Simulated failure` runs `exit 1`.
3. The action runs with `if: failure()` and no `reason`, so failed-step detection is exercised.

The workflow name contains "Test", so its tickets are easy to tell apart from real ones. Running it twice checks repeat detection; wait a minute between runs, because Jira's search index can lag. The run is red by design.

### D8. Caller contract

Callers:
- add `actions: read` to `permissions:`
- add the step last
- gate it with `if: failure() && github.event_name == 'schedule'`, so manual runs don't file tickets
- pass the two Jira secrets
- pin the action to `@v1`

A caller with a warning-only "can't merge" path adds that step's outcome to the condition and passes a fixed `reason`.

### D9. Configurable ticket fields

| Input | Default | Sent as |
|---|---|---|
| `project-key` | `IGDD` | `project.key` |
| `issue-type` | `Bug` | `issuetype.name` |
| `components` | the `component` input | `components[].name`, split on commas |
| `labels` | `ci-failure` | `labels`, plus the repeat-detection label |
| `priority` | empty | `priority.name`, only when set |
| `assignee-account-id` | empty | `assignee.accountId`, only when set |
| `epic-key` | empty | `parent.key`, only when set |
| `sprint` | `active` | the Sprint field, set to the active sprint's ID when `active` |
| `board-id` | `27` | the board for the active-sprint lookup |
| `ai-use` | `NA` | the "AI Use" field, only when set |

**Why these defaults:**
- **`sprint: active`:** a nightly failure shows on the sprint board straight away. Callers can pass `sprint: none`.
- **`ai-use: NA`:** a Bug can't be moved to a Done status until "AI Use" is set.

**Why repeats never change fields:** someone may have reassigned, re-prioritised or re-scheduled the ticket, and the action should not undo that.

Invalid values, such as an unknown component, are rejected by Jira, and the step fails with Jira's message.

## Risks / Trade-offs

- **[Two failures at the same moment]** → both may create tickets. Very unlikely for nightly jobs, so accepted.
- **[Jira's search index lags new tickets]** → a repeat within seconds of a create could miss it. Not an issue for nightly runs.
- **[Renaming a workflow or step changes the key]** → the next failure opens a new ticket. Acceptable and rare.
- **[One credential shared across repos]** → anyone with write access to those repos could read it through a workflow. Use an account limited to the project.
- **[Step detection depends on `actions: read`]** → without it the failure is reported as `unknown step`, and all such failures in a component share one ticket.
- **[A floating `v1` tag]** → callers get changes immediately, the same as `cve-scan`. Pin `@v1.x.y` for exact reproducibility.

## Migration Plan

1. Build the action and self-test, and verify them end to end against Jira from a branch.
2. Open a PR to `main` labelled `bump:minor`. Merging releases `v1.1.0` and moves `v1`.
3. Add the step to each caller in a separate PR.

**Rollback:** remove the caller step (one revert per repo), or revert the action here. The next release moves `v1` back.
