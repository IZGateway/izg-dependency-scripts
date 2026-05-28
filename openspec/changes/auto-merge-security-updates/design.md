# Design: auto-merge-security-updates

## Overview

This document records the technical decisions for the `auto-merge-security-updates` CR.
It covers file layout, token strategy, workflow trigger architecture, PR identification,
merge mechanism, failure detection, Jira integration, and migration sequencing.

---

## Design Decisions

### DD-1: File Layout in `izg-dependency-scripts`

New files added by this CR:

```
.github/
  workflows/
    security-updates.yml          # reusable workflow_call (was copy-pasted in consumers)
    auto-merge-security-updates.yml  # reusable workflow_call for PR auto-merge
    failure-notification.yml      # reusable workflow_call for Jira ticket creation
  actions/
    jira-create-issue/
      action.yml                  # composite action — Jira REST API wrapper
      README.md                   # usage docs; canonical pattern note
```

Consuming projects replace their `security-updates.yml` with a thin caller and add:

```
.github/
  workflows/
    security-updates.yml          # thin workflow_call caller (replaces copy-paste)
    auto-merge-security-updates.yml  # thin workflow_call caller
    post-merge-failure.yml        # thin workflow_call caller (push trigger)
```

**Rationale:** Separating the three reusable workflows into distinct files keeps each
concern independently callable and versioned. A monolithic file would force consumers
to trigger all behavior from one entry point, complicating selective reuse in future CRs.

---

### DD-2: Token Strategy

| Operation | Token | Reason |
|---|---|---|
| Checkout in `security-updates.yml` | `IZGW_ALL_REPO_ACCESS_TOKEN` | `GITHUB_TOKEN` cannot create PRs that trigger other workflows; cross-repo token required for label application |
| `gh pr merge` in `auto-merge-security-updates.yml` | `IZGW_ALL_REPO_ACCESS_TOKEN` | Merge requires `contents: write` + `pull-requests: write` beyond default token scope in reusable workflows |
| Read-only steps (checkout for tests, status reads) | `GITHUB_TOKEN` | Least-privilege for steps that do not write |
| Jira API calls | `JIRA_API_TOKEN` (secret) | Separate credential; never mixed with GitHub tokens |

**Rationale:** Using `IZGW_ALL_REPO_ACCESS_TOKEN` for checkout in `security-updates.yml`
is necessary because a PR created with `GITHUB_TOKEN` does not trigger `pull_request`
workflow events in the target repository (GitHub security restriction). Without this,
the `auto-merge-security-updates` workflow would never fire on the created PR.

---

### DD-3: Reusable Workflow Reference Pattern

Consuming projects reference reusable workflows using a pinned branch ref:

```yaml
uses: IZGateway/izg-dependency-scripts/.github/workflows/security-updates.yml@main
```

**Rationale:** Using `@main` (rather than a SHA pin or tag) is consistent with the
existing IZ Gateway pattern for internal reusable workflows and avoids the operational
overhead of updating pins on every release. Since `izg-dependency-scripts` is an
internal trusted repository, the security tradeoff is acceptable. If the project adopts
release tags in a future CR, callers can be updated to `@vX.Y.Z`.

---

### DD-4: PR Identification — Dual Criteria

A PR is a security update PR if and only if **both** are true:

1. Head branch matches `automated-security-updates-*`
2. PR carries the label `security update`

The label is applied at PR creation time by the centralized `security-updates.yml`
(`gh pr create --label security update`).

**Rationale:** Branch name alone is guessable — any developer could push a branch named
`automated-security-updates-manual-test` and trigger auto-merge. Label alone could be
applied to any PR by anyone with triage access. The combination requires both the
automated branch naming convention AND the label applied by the centralized workflow,
making accidental or malicious triggering significantly harder. See spec
`auto-merge-workflow` Requirement: PR Identification.

---

### DD-5: Auto-Merge Mechanism

Use `gh pr merge --squash --auto` rather than enabling GitHub's native auto-merge via
the API.

```yaml
- name: Merge PR
  env:
    GH_TOKEN: ${{ secrets.IZGW_ALL_REPO_ACCESS_TOKEN }}
  run: gh pr merge ${{ inputs.pr-number }} --squash --auto --delete-branch
```

**Rationale:** `--auto` defers the actual merge until all required branch protection
checks pass — it does not merge immediately. This is equivalent to clicking "Enable
auto-merge" in the GitHub UI. Using `gh pr merge` is simpler than the REST API and
handles the required-checks gate natively without polling. Squash merge keeps the
default branch history clean (one commit per security update batch).

---

### DD-6: Check Status Detection

The `auto-merge-security-updates` workflow uses the `pull_request` event with types
`opened`, `synchronize`, `reopened`, `labeled` — **not** `check_suite` or
`check_run` events.

The workflow calls `gh pr checks` to read current check status at trigger time. If any
required check is `fail`, it calls `failure-notification`. If all are `success`, it
calls `gh pr merge --squash --auto`.

**Rationale:** `check_run` events fire for every individual check update, causing the
workflow to run many times per PR. Using `pull_request` events and reading status at
trigger time is simpler and avoids duplicate Jira ticket creation. The `--auto` flag
on `gh pr merge` handles the merge timing correctly without requiring the workflow to
re-evaluate check status after each check completes.

---

### DD-7: Post-Merge Failure Detection

The post-merge failure workflow fires on `push` to the default branch. It detects
whether the triggering commit is a security update merge by matching the commit message
against the pattern `chore(deps): security and dependency updates`.

```yaml
on:
  push:
    branches: [develop]

jobs:
  check-post-merge:
    if: contains(github.event.head_commit.message, 'chore(deps): security and dependency updates')
```

**Rationale:** The commit message is the most reliable signal available on a `push`
event. The squash merge commit message is controlled by the `auto-merge-security-updates`
workflow (set at merge time), making it predictable. Alternative approaches (checking
merged PR labels via API on every push) would require an extra API call and add latency
to every push on the default branch.

---

### DD-8: Failure Notification — Single Ticket Per Run

The `failure-notification` workflow creates exactly one Jira ticket per invocation,
regardless of how many checks fail. All failing check names are concatenated into the
ticket description.

**Rationale:** Multiple Jira tickets for a single failed run create noise. The engineer
investigating the failure needs one ticket with the full context. If the same PR fails
on a re-run, a second ticket is created — deduplication across runs is not in scope
for this CR.

---

### DD-9: `jira-create-issue` — `curl` Implementation

The `jira-create-issue` composite action uses `curl` with Basic Auth against the Jira
REST API v3 `POST /rest/api/3/issue` endpoint. Authentication credentials are passed
via environment variables to ensure GitHub's secret masking applies.

```yaml
- name: Create Jira issue
  shell: bash
  env:
    JIRA_URL: ${{ inputs.jira-url }}
    JIRA_USER: ${{ inputs.jira-user }}
    JIRA_TOKEN: ${{ inputs.jira-api-token }}
  run: |
    RESPONSE=$(curl -s -w "\n%{http_code}" \
      -X POST \
      -H "Content-Type: application/json" \
      -H "Authorization: Basic $(echo -n "$JIRA_USER:$JIRA_TOKEN" | base64)" \
      "$JIRA_URL/rest/api/3/issue" \
      -d "$(jq -n \
        --arg pk "${{ inputs.project-key }}" \
        --arg it "${{ inputs.issue-type }}" \
        --arg s "${{ inputs.summary }}" \
        --arg d "${{ inputs.description }}" \
        '{fields:{project:{key:$pk},issuetype:{name:$it},summary:$s,description:{type:"doc",version:1,content:[{type:"paragraph",content:[{type:"text",text:$d}]}]}}}'
      )")
    HTTP_CODE=$(echo "$RESPONSE" | tail -1)
    BODY=$(echo "$RESPONSE" | head -n -1)
    if [ "$HTTP_CODE" != "201" ]; then
      echo "::error::Jira API returned HTTP $HTTP_CODE: $BODY"
      exit 1
    fi
    ISSUE_KEY=$(echo "$BODY" | jq -r '.key')
    echo "issue-key=$ISSUE_KEY" >> "$GITHUB_OUTPUT"
    echo "issue-url=$JIRA_URL/browse/$ISSUE_KEY" >> "$GITHUB_OUTPUT"
```

**Rationale:** `curl` and `jq` are available on all GitHub-hosted `ubuntu-latest`
runners without additional setup steps. Using a third-party Jira action would introduce
an external dependency that could break silently on version changes. The REST API v3
`description` field requires Atlassian Document Format (ADF) JSON, not plain text —
the `jq` construction above handles that correctly.

---

### DD-10: Migration Sequence

Migration for each consuming project follows this order:

1. Add `JIRA_URL`, `JIRA_USER`, `JIRA_API_TOKEN` repository secrets
2. Replace `security-updates.yml` with thin caller
3. Add `auto-merge-security-updates.yml` thin caller
4. Add `post-merge-failure.yml` thin caller
5. Open a PR, get it reviewed, merge to default branch
6. Trigger a manual `workflow_dispatch` run to verify end-to-end PR creation and labeling
   > The `security update` label (`#2ea7e0`) is created automatically on first run by the
   > centralized workflow (`gh label create ... || true`) — no manual label creation needed.
7. Verify auto-merge fires (or manually test with a dummy `security update`-labeled PR)

**Rationale:** Secrets must exist before the first automated run; deploying the workflows
without them risks a confusing auth failure before any useful work is done. Label creation
is handled by the workflow itself — one less manual step per repository.

**Migration order:** `izg-configuration-console` first; `izg-transformation-ui` second.
`izg-configuration-console` is the more complex project (has both quality-check and
test scripts that differ from defaults) and is therefore the better verification target.

---

### DD-11: Cron Stagger

Each consuming project's thin caller preserves its original cron offset:

- `izg-configuration-console`: `0 3 * * *` (3:00 AM UTC)
- `izg-transformation-ui`: `15 3 * * *` (3:15 AM UTC)

The `security-updates-workflow` spec's `cron-offset` input is removed from the design
— the stagger is owned by the thin caller's `schedule` trigger, not by the reusable
workflow.

**Rationale:** The reusable workflow has no awareness of when it is scheduled; it runs
when called. Putting the cron in the thin caller is the correct separation of concerns
and requires no additional input to the reusable workflow.

---

### DD-12: `workflow_dispatch` Channel Input Forwarding

The thin caller exposes a `dependency_scripts_channel` `workflow_dispatch` input
(matching the original) and forwards it to the reusable workflow's
`dependency-scripts-channel` input.

```yaml
on:
  workflow_dispatch:
    inputs:
      dependency_scripts_channel:
        description: 'npm tag for @izgateway/dependency-scripts'
        required: false
        default: 'latest'
        type: choice
        options: [latest, dev]

jobs:
  security-updates:
    uses: IZGateway/izg-dependency-scripts/.github/workflows/security-updates.yml@main
    with:
      dependency-scripts-channel: ${{ inputs.dependency_scripts_channel }}
      base-branch: develop
      quality-check-command: npm run code-quality-check
      test-command: npm run test
      build-command: npm run build
    secrets:
      NPM_TOKEN: ${{ secrets.NPM_TOKEN }}
      IZGW_ALL_REPO_ACCESS_TOKEN: ${{ secrets.IZGW_ALL_REPO_ACCESS_TOKEN }}
```

**Rationale:** Preserving the `workflow_dispatch` input with identical option labels
ensures developers who use the manual trigger do not notice any change in the UI.
