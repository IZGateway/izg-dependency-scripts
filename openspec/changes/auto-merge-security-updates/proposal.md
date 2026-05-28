# Proposal: Auto-Merge Security Updates

## Date
2026-05-28

## Status
Proposed

## Jira
[IGDD-2969](https://izgateway.atlassian.net/browse/IGDD-2969) — Automatically merge automated version bumps

## User Stories

As a developer maintaining IZ Gateway repositories, I want automated security version bumps
to be merged automatically when the build passes, so that patch updates are applied without
manual intervention, failures are escalated promptly, and security changes are visible in
release notes.

## Success Criteria

**Auto-merge:**
- **GIVEN** Security Updates has pushed a PR patching dependency versions,<br>
  **WHEN** all required checks pass for that build,<br>
  **THEN** the PR is automatically merged and closed.

- **WHEN** the checks fail for the build,<br>
  **THEN** a TODO ticket is created on the IGDD Board to investigate the failure, with the reason for failure and logs attached.

**Post-merge build failure:**
- **GIVEN** a security update PR has been merged,<br>
  **WHEN** checks finish and there was an error building, deploying, or testing,<br>
  **THEN** a TODO ticket is created on the IGDD Board to investigate why the post-merge build failed.

**Release notes:**
- **GIVEN** patches are successfully made during the security update process,<br>
  **WHEN** release notes are generated,<br>
  **THEN** a Security Updates section is included that reports what patches were applied.

## Scope Note

This CR covers PRs created by the IZ Gateway security update automation
(`fix-all-vulnerabilities.js`), identified by a `security update` label applied at
PR creation time. **Dependabot PRs are explicitly out of scope** — Dependabot runs
with a restricted token that prevents it from triggering other workflows, and GitHub
provides its own native auto-merge mechanism for those. Mixing the two would add
complexity without benefit.

## Summary

IZ Gateway projects run `fix-all-vulnerabilities.js` (from `izg-dependency-scripts`) to
patch known CVEs by bumping dependency versions. Currently the `security-updates.yml`
workflow that orchestrates this process is **copy-pasted verbatim** into every consuming
project — `izg-configuration-console` and `izg-transformation-ui` have identical files
differing only by cron offset. Any improvement to the process must be made in every repo
separately.

This CR consolidates the security update process into `izg-dependency-scripts` by:

1. Centralizing the entire `security-updates.yml` as a reusable `workflow_call` workflow,
   so consuming projects have a thin caller and updates propagate automatically.
2. Applying a `security update` label at PR creation time inside the centralized workflow,
   providing reliable PR identification that is more tamper-resistant than branch name alone.
3. Automatically merging a security update PR when all required status checks pass.
4. Creating an IGDD TODO ticket when a pre-merge build fails, with failure reason and logs.
5. Creating an IGDD TODO ticket when a post-merge build fails.

The reusable `fix-all-vulnerabilities` workflow (invoked by consuming projects via
`workflow_call`) already creates the security update PRs. This CR adds two new
behaviors that consuming projects must adopt as a migration step:

1. **PR checks (`pull_request` trigger)** — GIVEN a PR is opened by the security update
   process, WHEN checks pass, THEN auto-merge the PR; WHEN checks fail, THEN create an
   IGDD TODO ticket.
2. **Post-merge checks (`push` / merge trigger)** — GIVEN a merge was completed, WHEN
   downstream checks fail (build, deploy, test), THEN create an IGDD TODO ticket.

All behaviors are packaged as reusable workflows and composite actions in
`izg-dependency-scripts`. Migration of consuming projects (`izg-configuration-console`,
`izg-transformation-ui`) **is in scope** for this CR — the CR is not complete until the
reusable workflows have been integrated and tested in at least one consuming project. The
migration changes live in those downstream repos but are tracked and verified here.

## What Changes

- **NEW** Reusable `workflow_call` workflow `security-updates.yml` in `.github/workflows/`
  — centralizes the entire security update process (ncu, override updates, vulnerability
  fixes, build/test, PR creation) with project-specific steps exposed as inputs. Replaces
  the copy-pasted `security-updates.yml` in each consuming project.
- **NEW** `security update` label applied at PR creation time within the centralized
  workflow — provides reliable, tamper-resistant PR identification.
- **NEW** Reusable `workflow_call` workflow `auto-merge-security-updates.yml` —
  triggers on `pull_request` events for labeled PRs; merges on pass, creates IGDD TODO
  ticket on failure.
- **NEW** Post-merge failure detection — triggers on `push` to the default branch after
  a security update merge; creates IGDD TODO ticket if build/deploy/test fails.
- **NEW** Reusable composite action `jira-create-issue` in `.github/actions/` — wraps
  the Jira REST API `curl` call to create a ticket with structured fields (project, issue
  type, summary, description). Accepts `JIRA_URL`, `JIRA_USER`, and `JIRA_API_TOKEN` as
  inputs. **This is the canonical pattern for Jira integration from GitHub Actions across
  all IZ Gateway projects** — future CRs requiring Jira ticket creation should reuse or
  extend this action rather than routing through email-to-helpdesk.
- **NEW** Security patch changelog capture — records the set of bumped versions so
  release note generation can include a Security Updates section.
  > ⚠️ **Open Question:** Neither `izg-configuration-console` nor `izg-transformation-ui`
  > currently generate release notes in any automated way. This capability is deferred
  > pending a decision on the release notes strategy for these projects. It may be
  > addressed in a follow-on CR.
- **MIGRATION** Consuming projects (`izg-configuration-console`,
  `izg-transformation-ui`) replace their current `security-updates.yml` with a thin
  `workflow_call` caller and add the `auto-merge-security-updates` and post-merge
  failure workflows; migration and verification are in scope for this CR.

## Capabilities

### New Capabilities

- `security-updates-workflow`: Reusable `workflow_call` workflow that centralizes the
  entire security update process. Inputs: `base-branch`, `quality-check-command`,
  `test-command`, `build-command`, `dependency-scripts-channel`. Secrets: `NPM_TOKEN`,
  `IZGW_ALL_REPO_ACCESS_TOKEN`. Applies `security update` label at PR creation.
- `auto-merge-workflow`: Reusable `workflow_call` workflow triggered on `pull_request`
  events in consuming projects; detects security update PRs by the `security update`
  label, merges the PR when all required checks pass, and triggers failure notification
  when they fail.
- `failure-notification`: Creates an IGDD TODO Jira ticket directly via the
  `jira-create-issue` composite action; invoked by both the auto-merge workflow
  (pre-merge check failure) and a separate post-merge push trigger (build/deploy/test
  failure after merge).
- `jira-create-issue`: Reusable composite action that creates a Jira issue via the REST
  API. Accepts `JIRA_URL`, `JIRA_USER`, `JIRA_API_TOKEN`, `project-key`, `issue-type`,
  `summary`, and `description` as inputs. Replaces the email-to-helpdesk workaround and
  establishes the canonical Jira integration pattern for all IZ Gateway GitHub Actions
  workflows.
- `migration`: Replaces the copy-pasted `security-updates.yml` in each consuming project
  with a thin `workflow_call` caller; adds `auto-merge-security-updates` and post-merge
  failure workflows. CR is not complete until migration is verified in at least one
  consuming project.

### Modified Capabilities

_(none — existing workflows are not changing behavior)_

## Impact

- **`izg-dependency-scripts`** — adds new reusable workflow and composite action files;
  no changes to existing `ci.yml`, `validate.yml`, or the `cve-scan` composite action.
- **`izg-configuration-console`** (migration, in scope) — `security-updates.yml`
  replaced with thin caller; `auto-merge-security-updates` and post-merge failure
  workflows added; verified as part of this CR.
- **`izg-transformation-ui`** (migration, in scope) — same as above.
- **Jira API access** — `jira-create-issue` composite action requires `JIRA_URL`,
  `JIRA_USER`, and `JIRA_API_TOKEN` secrets in each consuming repository. This replaces
  the current email-to-helpdesk ticket creation workaround and becomes the standard
  pattern going forward.
