# Spec: migration

## Purpose

Replace the copy-pasted `security-updates.yml` in each consuming project with a thin
`workflow_call` caller and add the `auto-merge-security-updates` and post-merge failure
workflows. This CR is not complete until migration is verified in at least one consuming
project (`izg-configuration-console`); `izg-transformation-ui` follows the same steps.

## Requirements

### Requirement: Thin Caller Pattern

Each consuming project replaces its `security-updates.yml` with a thin caller that
delegates entirely to the reusable workflow in `izg-dependency-scripts`.

The thin caller MUST:
- Use the `workflow_call` trigger to invoke `.github/workflows/security-updates.yml`
  from `izg-dependency-scripts`.
- Pass project-specific inputs (`base-branch`, `quality-check-command`, `test-command`,
  `build-command`) that differ from defaults.
- Pass required secrets (`NPM_TOKEN`, `IZGW_ALL_REPO_ACCESS_TOKEN`) explicitly.
- Preserve the original `schedule` cron and `workflow_dispatch` triggers on the caller.

The thin caller MUST NOT duplicate any workflow logic — all steps live in
`izg-dependency-scripts`.

#### Scenario: Thin caller invokes centralized workflow
WHEN the consuming project's scheduled cron fires<br>
THEN the thin caller triggers the reusable `security-updates.yml` in
`izg-dependency-scripts` with the project's inputs and secrets<br>
AND the workflow runs exactly as before in the context of the consuming repository.

#### Scenario: Thin caller uses workflow_dispatch
WHEN a developer manually triggers the consuming project's workflow<br>
AND selects a `dependency-scripts-channel` value<br>
THEN the value is forwarded to the reusable workflow's `dependency-scripts-channel`
input.

---

### Requirement: Auto-Merge Workflow Addition

Each consuming project must add a new workflow file (e.g.,
`auto-merge-security-updates.yml`) that calls the reusable `auto-merge-workflow` from
`izg-dependency-scripts`.

This workflow fires on `pull_request` events (types: `opened`, `synchronize`,
`reopened`, `labeled`) targeting the consuming project's default branch.

It passes:
- `IZGW_ALL_REPO_ACCESS_TOKEN` secret (for merge operations)
- `JIRA_URL`, `JIRA_USER`, `JIRA_API_TOKEN` secrets (for failure notifications)

#### Scenario: Security-update PR passes all checks
WHEN all required checks pass on a security-update PR in the consuming project<br>
THEN the auto-merge workflow merges the PR automatically.

#### Scenario: Security-update PR fails a check
WHEN a required check fails on a security-update PR<br>
THEN the auto-merge workflow creates an IGDD TODO Jira ticket and takes no merge action.

---

### Requirement: Post-Merge Failure Workflow Addition

Each consuming project must add a workflow (e.g.,
`security-update-post-merge-failure.yml`) that fires on `push` to the default branch
and invokes the `failure-notification` reusable workflow when:
1. The triggering commit message matches the security-update commit pattern
   (`chore(deps): security and dependency updates`), AND
2. A subsequent CI job (build, deploy, or test) on that branch fails.

The workflow passes `JIRA_URL`, `JIRA_USER`, `JIRA_API_TOKEN`, and branch context as
inputs/secrets.

#### Scenario: Post-merge CI failure on security-update commit
WHEN the default branch CI fails after a security-update merge<br>
THEN the post-merge failure workflow creates an IGDD TODO Jira ticket with the
failing job name and run URL.

---

### Requirement: Pre-Migration Prerequisites

Before the first run of the migrated workflows in a consuming project, the following
must be in place:

1. **`security-update` label** — the label must exist in the consuming repository.
   Create it via `gh label create "security-update" --color "ee0701" --description
   "Automated security dependency update PR" --repo <owner>/<repo>`.
2. **Repository secrets** — `JIRA_URL`, `JIRA_USER`, and `JIRA_API_TOKEN` must be
   set in the consuming repository's Actions secrets.
3. **Branch protection** — the consuming project's default branch protection rules
   must include the auto-merge workflow's status check as a required check (or the
   PR must be configured for auto-merge after the required checks are defined).

#### Scenario: Label missing before first run
WHEN the thin caller creates a security-update PR<br>
AND the `security-update` label does not exist in the repository<br>
THEN `gh pr create --label security-update` fails; the prerequisite checklist must
ensure label creation before the first automated run.

#### Scenario: Jira secrets missing before first run
WHEN a required check fails on a security-update PR<br>
AND `JIRA_API_TOKEN` is not set in the repository<br>
THEN the `failure-notification` workflow fails with an authentication error; the
prerequisite checklist must ensure secrets are configured before migration.

---

### Requirement: Verification

Migration for each consuming project is not complete until the following are verified:

1. A scheduled (or manually triggered) run of the thin caller successfully creates a
   `security-update`-labeled PR in the consuming project.
2. A test PR carrying the `security-update` label is either auto-merged (if checks
   pass) or produces an IGDD TODO ticket (if checks are forced to fail).
3. All existing nightly and CI workflows in the consuming project continue to function
   without regression.

#### Scenario: Migration verified in izg-configuration-console
WHEN a security-update PR is created via the thin caller in `izg-configuration-console`<br>
AND the PR carries the `security-update` label<br>
AND the auto-merge workflow merges or notifies correctly<br>
THEN `izg-configuration-console` migration is marked complete.

#### Scenario: Migration verified in izg-transformation-ui
WHEN the same verification passes for `izg-transformation-ui`<br>
THEN that project's migration is also marked complete and the CR can be closed.
