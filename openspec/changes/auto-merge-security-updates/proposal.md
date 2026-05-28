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
- **GIVEN** Security Updates has pushed a PR patching dependency versions,
  **WHEN** all required checks pass for that build,
  **THEN** the PR is automatically merged and closed.

- **WHEN** the checks fail for the build,
  **THEN** an email is sent to support@izgateway.org for disposition as a TODO on the IGDD
  Board to investigate the failure, with the reason for failure and logs attached.

**Post-merge build failure:**
- **GIVEN** a security update PR has been merged,
  **WHEN** checks finish and there was an error building, deploying, or testing,
  **THEN** an email is sent to support@izgateway.org for disposition as a TODO on the IGDD
  Board to investigate why the post-merge build failed.

**Release notes:**
- **GIVEN** patches are successfully made during the security update process,
  **WHEN** release notes are generated,
  **THEN** a Security Updates section is included that reports what patches were applied.

## Summary

IZ Gateway projects run `fix-all-vulnerabilities.js` (from `izg-dependency-scripts`) to
patch known CVEs by bumping dependency versions. Currently these patches open PRs that
require a human to review and merge, even when the build is clean. This introduces
unnecessary delay in getting security patches applied and risks patches languishing
unmerged.

This CR introduces a reusable GitHub Actions workflow (hosted in `izg-dependency-scripts`)
that:

1. Automatically merges a security update PR when all required status checks pass.
2. Sends an email to `support@izgateway.org` and creates an IGDD TODO ticket when a
   pre-merge build fails, attaching failure reason and logs.
3. Sends an email to `support@izgateway.org` and creates an IGDD TODO ticket when a
   post-merge build fails.
4. Records applied patches so they appear in a **Security Updates** section of the
   project's release notes.

The workflow lives in `izg-dependency-scripts` and is consumed by consuming projects
(initially `izg-configuration-console` and `izgw-transform-ui`) via `workflow_call`.
Migration steps in those consuming projects are out of scope for this CR but will be
tracked in their respective repos.

## What Changes

- **NEW** Reusable workflow `auto-merge-security-updates.yml` in
  `.github/workflows/` — orchestrates auto-merge and failure notification logic.
- **NEW** Failure notification step — on pre-merge check failure, sends email to
  `support@izgateway.org` and opens an IGDD TODO Jira ticket with logs attached.
- **NEW** Post-merge failure notification step — on post-merge build/deploy/test failure,
  sends email and opens an IGDD TODO Jira ticket.
- **NEW** Security patch changelog capture — records the set of bumped versions so
  release note generation can include a Security Updates section.
- **MIGRATION** (out of scope for this CR) Consuming projects (`izg-configuration-console`,
  `izgw-transform-ui`) must update their CI workflows to call this reusable workflow.

## Capabilities

### New Capabilities

- `auto-merge-workflow`: Reusable `workflow_call` workflow that merges a security-update
  PR when required checks pass; identifies security-update PRs by label or author
  (e.g., `dependabot[bot]` or a `security-update` label).
- `failure-notification`: Sends email to `support@izgateway.org` and creates an IGDD TODO
  Jira ticket with failure details and logs, triggered by both pre-merge check failures and
  post-merge build/deploy/test failures.
- `security-release-notes`: Captures the list of dependency version bumps applied by a
  security update PR and makes them available to the release workflow as a structured
  artifact for inclusion in release notes under a **Security Updates** section.

### Modified Capabilities

_(none — existing workflows are not changing behavior)_

## Impact

- **`izg-dependency-scripts`** — adds three new workflow/script files; no changes to
  existing `ci.yml`, `validate.yml`, or the `cve-scan` composite action.
- **`izg-configuration-console`** (migration, separate CR) — must add a workflow_call step
  to invoke `auto-merge-security-updates`.
- **`izgw-transform-ui`** (migration, separate CR) — same as above.
- **Jira API access** — failure notification requires a secret (`JIRA_API_TOKEN`) and
  `JIRA_URL` to be available in the consuming repository's secrets to open IGDD TODO
  tickets programmatically.
- **Email delivery** — requires an SMTP or GitHub Actions email action (e.g., via
  `dawidd6/action-send-mail`) and an appropriate SMTP secret in the repository.
