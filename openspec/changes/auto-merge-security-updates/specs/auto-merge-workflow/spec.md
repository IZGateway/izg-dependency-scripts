# Spec: auto-merge-workflow

## Purpose

Reusable GitHub Actions workflow that automatically merges a security update PR when all
required status checks pass, and triggers failure notification when they fail.

## Requirements

### Requirement: PR Identification

A PR is considered a security update PR if it meets **both** of the following:

1. Its head branch name matches the pattern `automated-security-updates-*`.
2. It carries the label `security update`.

The `security-updates.yml` workflow in consuming projects is responsible for applying the
`security update` label at PR creation time (see `migration` spec). Dual identification
(branch pattern + label) guards against accidental triggering by non-security PRs that
happen to match one criterion.

#### Scenario: PR matches both criteria
WHEN a PR is opened or a status check completes on a PR  
AND the head branch matches `automated-security-updates-*`  
AND the PR carries the label `security update`  
THEN the PR is treated as a security update PR and auto-merge evaluation proceeds.

#### Scenario: PR matches only one criterion
WHEN a PR is opened or updated  
AND only one of the two criteria is satisfied  
THEN the workflow takes no auto-merge action and emits a warning annotation.

---

### Requirement: Auto-Merge on Pass

GIVEN a PR has been identified as a security update PR,  
WHEN all required status checks report success,  
THEN the workflow merges the PR using squash merge and the PR is closed.

The merge commit message must include the PR title and PR number.

#### Scenario: All checks pass
WHEN all required checks on a security update PR report `success`  
THEN `gh pr merge --squash --auto` is called, the PR is merged, and the branch is deleted.

---

### Requirement: Failure Notification on Pre-Merge Failure

GIVEN a PR has been identified as a security update PR,  
WHEN one or more required status checks report `failure` or `cancelled`,  
THEN the workflow invokes the `failure-notification` reusable workflow with:
- context: `pre-merge`
- PR number and URL
- failing check names and their log URLs

#### Scenario: One or more checks fail
WHEN a required check on a security update PR reports `failure`  
THEN the `failure-notification` workflow is called with pre-merge context and the check
details; no merge attempt is made.

---

### Requirement: Workflow Interface

The workflow is defined as a reusable `workflow_call` workflow and also fires on
`pull_request` events (types: `opened`, `synchronize`, `reopened`, `labeled`) targeting
the consuming project's default branch.

Inputs (all optional, with defaults):
- `label` (string, default: `security update`) — label that identifies security update PRs.
- `branch-prefix` (string, default: `automated-security-updates-`) — branch name prefix.
- `merge-method` (string, default: `squash`) — merge strategy (`squash`, `merge`, `rebase`).

Required secrets (passed through from consuming project):
- `GH_TOKEN` — token with `contents: write` and `pull-requests: write` permissions.
- `JIRA_API_TOKEN` — for failure-notification Jira ticket creation.

#### Scenario: Called via workflow_call
WHEN a consuming project calls this workflow via `workflow_call`  
THEN all inputs and secrets are forwarded from the caller.

#### Scenario: Called via pull_request event
WHEN a `pull_request` event fires on a security update PR  
THEN the workflow evaluates current check status and merges or notifies as appropriate.
