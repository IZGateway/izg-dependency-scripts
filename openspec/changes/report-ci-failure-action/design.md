# Design: `report-ci-failure` composite action

## Context

Today, three nightly dependency workflows open a PR and auto-merge it once its checks pass:
- `izgw-bom` `dependency-updates.yml`, 07:00 UTC on weekdays
- `izg-configuration-console` `security-updates.yml`, 03:00 UTC daily
- `izg-transformation-ui` `security-updates.yml`, 03:15 UTC daily

The bot has merged the last several PRs in each repo with no human involved. When a run fails, the only signal is a red run in the Actions tab.

The only existing precedent for failure reporting is `izgw-performance-test`, which is private. On failure it sends an email with `dawidd6/action-send-mail@v17` through the SES relay `email-smtp.us-east-1.amazonaws.com:465`, and copies `devops@izgateway.opsgenie.net`. Opsgenie then creates the Jira ticket. The SMTP credentials are org secrets `MAIL_USERNAME` and `MAIL_PASSWORD`; the perf repo has no repo-level copies.

Constraints:
- **Public callers.** The three calling repos are public, and so is this one, so anything in a workflow file is world-readable.
- **No secrets in composite actions.** A composite action cannot read `secrets.*`. `cve-scan` already handles this by taking secrets as inputs.
- **Dispatch needs the default branch.** `workflow_dispatch` only works for workflow files that exist on the default branch, `main`.
- **Releases.** Merging to `main` releases the repo: `ci.yml` publishes the npm package and force-moves the `v1` tag.

People involved:
- Keith, who asked for this ticket
- the team, who receive the tickets
- an org admin, who owns the secrets
- whoever owns the Opsgenie email integration

## Goals / Non-Goals

**Goals:**
- One implementation that any IZ Gateway workflow can call in about 8 lines.
- The same failure, in the same component, always produces the same subject, so Opsgenie can treat a repeat as the same alert. A different failure produces a different subject.
- Nothing in the action or its callers reveals the Opsgenie address or log content.
- The whole path (action, email, Opsgenie, Jira) is proven by a self-test before any product repo depends on it.

**Non-Goals:**
- Calling the Jira API directly, or setting Jira fields such as sprint, status or component. Opsgenie owns ticket creation.
- Deciding when a failure is worth reporting. That is the caller's `if:`.
- E2E failure reporting (IGDD-2762) and the Java nightly workflows (IGDD-2763 to IGDD-2766). They will reuse the action later.

## Decisions

### D1. Composite action, not a reusable workflow or copied steps

The action runs as a step inside the failing job.

**Why:** it can see that job's environment, for example `PR_URL` written to `$GITHUB_ENV` and the BOM's `steps.<id>.outcome`, so callers need no job-output wiring. It also follows the `cve-scan` pattern.

**Alternatives:**
- **Reusable workflow** (`workflow_call` with `needs:` and `if: failure()`). For: `secrets: inherit`. Against: the failed job's environment has to be passed out through job outputs, which means extra wiring in every caller.
- **Copying the send-mail step into each workflow.** This is what the perf test does. It is simplest, but there will be about nine copies eventually, and any drift between them breaks repeat detection.

### D2. Email Opsgenie, do not call Jira

The action reuses the path the perf test already uses.

**Why:** no Jira API token in GitHub, no new integration to build, and the team already receives tickets from it.

**Alternative:** call the Jira REST API directly. That needs a service-account token stored as an org secret, plus a lookup of the current sprint on board 27. The team ruled it out.

### D3. Subject is the repeat-detection key

The subject is `IZG CI failure: <component> - <workflow> - <failure description>`. It contains no date, run ID or SHA. Newlines are replaced with spaces, and the subject is capped at 130 characters, the Opsgenie alert message limit.

**Why:** the team wants a repeat of the same failure added as a comment on the existing ticket, and a different failure opened as a new ticket. Without Jira access, the only lever is what Opsgenie can match on, and the subject is the natural alias for its email integration. The failed step is a good-enough definition of "same failure": two different errors in `Build application` share a ticket, which is what you want while that step stays broken.

**Alternative:** include a hash of the error output in the subject. Rejected, because it would need log content, which conflicts with the no-logs rule, and timestamps in error messages would defeat repeat detection.

### D4. Failure description: reason, then last failed step in this job, then `unknown step`

Callers can pass `reason` for soft failures, such as the BOM's "PR left open". Otherwise the action calls `GET /repos/{repo}/actions/runs/{run_id}/attempts/{attempt}/jobs` with the job's token. It picks the job whose `runner_name` equals `$RUNNER_NAME`, and takes the name of the **last** step with `conclusion == "failure"`.

**Why the last failed step:** CC's `Run tests` step is `continue-on-error`, and it currently always fails because of the known Jest problem. Taking the first failed step would name `Run tests` every night and merge unrelated failures into one ticket. After the step that actually stopped the job, the only steps that run are `if: failure()` steps such as log uploads, which succeed, and the report step itself, which is still running. So the last failed step is the one that stopped the job.

**Why match on runner name:** in a workflow with several jobs, another job's failure must not be reported as this job's.

**Fallback:** any API or `jq` error falls through to `unknown step`. The lookup must never prevent a report. That is also why it runs with `continue-on-error` semantics and `|| true` handling inside the script.

### D5. Secrets and the address are inputs

`smtp-username`, `smtp-password` and `to` are required inputs. Callers pass `secrets.MAIL_USERNAME`, `secrets.MAIL_PASSWORD` and a new org secret, `secrets.JIRA_ALERT_EMAIL`.

**Why:** composite actions cannot read secrets. Keeping the address in a secret is the only thing stopping anyone who reads a public workflow from creating IGDD tickets.

**Empty `to`:** the action fails with a clear error. This is what happens when the org secret has not been shared with the calling repo. Sending nowhere silently would be worse.

### D6. Delivery uses `dawidd6/action-send-mail@v17` over SES

This is the same action, version, server, port, TLS setting and `from` address the perf test uses. They are exposed as inputs with those values as defaults, and the body uses `convert_markdown: true`.

**Why:** these settings are proven to reach Opsgenie today, and reusing them means no new third-party dependency to vet.

If sending fails, the step fails, so a broken reporter shows up in the run.

### D7. Self-test workflow in this repo

`test-report-ci-failure.yml` runs on `workflow_dispatch`, with a choice input `component` that defaults to `BOM`. It runs three steps:
1. Check out the repo.
2. A step named `Simulated failure` that runs `exit 1`.
3. `uses: ./.github/actions/report-ci-failure` with `if: failure()`, and no `reason`, so that step detection is exercised.

Because the workflow name contains "Test", the subject is distinct from every real alert. Running it twice with the same input checks repeat detection. The run is red by design.

The job sets `permissions: contents: read, actions: read`.

### D8. Caller contract

Callers:
- add `actions: read` to `permissions:`
- add the step last
- gate it with `if: failure() && github.event_name == 'schedule'`, so a developer's manual runs do not file tickets
- pin the action to `@v1`

The BOM also reports its warning-only "PR left open for review" path. Its condition becomes `github.event_name == 'schedule' && (failure() || steps.left-open.outcome == 'success')`, with an explicit `reason`.

## Risks / Trade-offs

- **[Opsgenie may not match repeat alerts on the subject]** → Each repeat failure would create a new ticket. The self-test runs twice before any caller is wired. If two tickets appear, whoever owns the Opsgenie email integration sets the alias to the subject, and the Jira action to comment on a repeat. This is Opsgenie configuration, not a code change.
- **[Repeat detection only works while the alert is open]** → Once someone closes the Opsgenie alert or the ticket, the next failure opens a new ticket. That is the desired behavior.
- **[Renaming a step changes the key]** → The next failure after a rename opens a new ticket. This is acceptable and rare.
- **[Org secrets not shared with a repo]** → The empty `to` fails loudly, as D5 describes. Rollout lists the secret-sharing step before any caller PR.
- **[Step detection depends on `actions: read` and on the API's view of the running job]** → The fallback is `unknown step`. The report is still sent, but every unknown-step failure in a component shares one key. The self-test checks detection on a real runner.
- **[Self-test files real tickets]** → One recognizable test ticket per verification. The person running it closes it afterwards.
- **[A floating `v1` tag means callers get changes immediately]** → This matches how `cve-scan` and `ecr-scan-report` are consumed. Callers that need exact reproducibility can pin to `@v1.x.y`.

## Migration Plan

1. Open a PR to `main` with the action, the self-test, README and Copilot-instructions updates, labelled `bump:minor`. The existing `validate.yml` actionlint job must pass.
2. Before merging, an org admin creates `JIRA_ALERT_EMAIL`, and shares it plus `MAIL_USERNAME` and `MAIL_PASSWORD` with this repo and the three calling repos.
3. Merge. `ci.yml` releases `v1.1.0` and moves `v1`. No workflow calls the action yet, so this is harmless.
4. Dispatch the self-test twice. Confirm:
   - one IGDD ticket, with a comment for the second run
   - the subject names `Simulated failure`
   - the body has the run link and no logs
5. Wire the callers in separate PRs: `izg-configuration-console`, `izg-transformation-ui`, `izgw-bom`.

**Rollback:**
- Remove the caller step, which is one revert per repo.
- If the action itself is broken, revert in this repo. The next release moves `v1` back to working code.

## Open Questions

- Who owns the Opsgenie email integration, in case step 4 shows that repeat detection needs configuring?
- Does Opsgenie put these tickets on the IGDD board with a component? The team said it doesn't matter for now.
