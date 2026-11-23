# Proposal: shared Maven security-update and auto-merge workflows

## Jira

- [IGDD-2766](https://izgateway.atlassian.net/browse/IGDD-2766): Auto-update izgw-transform dependencies as for izgw-bom (first consumer)
- Same story for the other Java services, to adopt these workflows: [IGDD-2763](https://izgateway.atlassian.net/browse/IGDD-2763) v2tofhir, [IGDD-2764](https://izgateway.atlassian.net/browse/IGDD-2764) izgw-core, [IGDD-2765](https://izgateway.atlassian.net/browse/IGDD-2765) izgw-hub

## Why

IGDD-2766 added a nightly workflow to izgw-transform that applies patch releases to the versions the project owns, opens a PR as `izg-dependency-bot`, and auto-merges it once the PR build, deploy and integration tests pass. It was tested end to end on 2026-11-16 and again, after hardening, on 2026-11-18.

That is about 300 lines of workflow in `security-updates.yml` plus about 110 lines of auto-merge job in `maven.yml`. izgw-core already has a copy (izgw-core PR #117) that differs only in Maven server ids, CI concurrency name and comments. izgw-hub and v2tofhir would be two more copies. Each fix, such as the `web-flow` committer correction found in testing, would have to be made four times, and the auto-merge safety checks are security-sensitive code that should exist once.

## What Changes

- **New reusable workflow** `.github/workflows/maven-security-updates.yml`: applies patch updates (`versions:use-latest-versions`, `versions:update-properties`) honouring the caller's exclusions file, runs a quick verify, creates a GitHub-signed commit through the Git Data API, opens the PR, closes superseded nightly PRs, and re-runs the PR's CI build if it is cancelled while queued. Repository-specific values are inputs.
- **New reusable workflow** `.github/workflows/auto-merge-security-update.yml`: called from the consumer's CI as a job that `needs:` the build. Checks provenance (activity log), content (allowed files, bot author, `web-flow` committer, verified signature), approves as `github-actions[bot]`, and merges with the bot token and `--match-head-commit`. Not specific to Maven (`allowed-files` input), so the npm repositories can reuse it.
- **Five new composite actions** in `.github/actions/` hold the logic; the two workflows above are short recipes that call them, so other flows (for example IGDD-2969's npm security updates, or izgw-bom) can reuse the parts:
  - `setup-izg-maven` (Maven): JDK, Maven and GitHub Packages credentials in `settings.xml`. Also usable by every IZ Gateway Maven workflow that writes `settings.xml` by hand today.
  - `maven-patch-updates` (Maven): apply patch updates, quick verify, PR description.
  - `open-signed-pr` (any ecosystem): GitHub-signed bot commit, PR, close superseded nightly PRs.
  - `rerun-cancelled-build` (any ecosystem): re-run a PR build cancelled in a concurrency queue.
  - `auto-merge-bot-pr` (any ecosystem): eligibility, provenance and content checks, approve, merge.
- **README** sections for the workflows and the actions, including what the calling repository needs.
- **Bump label:** `bump:minor`. New capabilities; nothing existing changes.

Consumers keep only a thin `security-updates.yml` caller, a short job in their CI workflow, `automation-exclusions.txt`, `versions-rules.xml` and their pom changes.

## Relationship to IGDD-2969

[IGDD-2969](https://izgateway.atlassian.net/browse/IGDD-2969) (`auto-merge-security-updates` change, not yet implemented) plans a central `security-updates.yml` and auto-merge for the npm repositories. This change does not modify it. Its auto-merge workflow is deliberately ecosystem-agnostic so IGDD-2969 can call it rather than build a second one. Where the two designs differ, this change uses what was tested on izgw-transform: the `izg-dependency-bot` App instead of `IZGW_ALL_REPO_ACCESS_TOKEN`, provenance and signature checks instead of a label, and an explicit approval plus `--match-head-commit` merge instead of `gh pr merge --auto` (repository auto-merge is off and `develop` requires an approval).

## Capabilities

### New Capabilities

- `maven-security-updates`: reusable workflow that opens the patch-update PR for a Maven project.
- `security-update-auto-merge`: reusable workflow that approves and merges the bot's PR after CI passes, only when its provenance and content checks pass.
- `bot-pr-actions`: the composite actions both workflows are built from, usable on their own.

### Modified Capabilities

_(none)_

## Impact

- **izg-dependency-scripts:** two new workflow files, five new composite actions, and README sections. No change to existing actions, workflows or npm scripts.
- **izgw-transform** (in scope): `security-updates.yml` becomes a thin caller; the auto-merge job in `maven.yml` becomes a `uses:` job. Pinned to `@v1`.
- **izgw-core, izgw-hub, v2tofhir:** not changed here; each adopts the workflows under its own ticket.
- **Public repository:** the workflows contain no internal hostnames, credentials or logs. Credentials come from the caller as secrets.

## Non-goals

- Filing Jira tickets when a nightly run or its PR build fails. The `report-ci-failure` action covers that; wiring it in is a follow-up.
- Moving the patch-only `versions-maven-plugin` default into izgw-bom so consumers need no pom override.
- Transitive dependency overrides (the izgw-bom workflow's auto-fix of transitives).
