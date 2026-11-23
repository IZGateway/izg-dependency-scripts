# Spec: maven-security-updates

This capability covers the reusable workflow `.github/workflows/maven-security-updates.yml`, which opens a pull request applying patch releases to a Maven project's own dependency and plugin versions.

## ADDED Requirements

### Requirement: Patch updates to project-owned versions only

The workflow SHALL run `versions:use-latest-versions` and `versions:update-properties` with the caller's exclusions and SHALL NOT change any artifact matching a pattern in the exclusions file. Patch-only behaviour SHALL come from the caller's `versions-maven-plugin` configuration.

#### Scenario: Upstream artifacts excluded
- **GIVEN** the exclusions file lists `gov.cdc.izgw:*`
- **WHEN** the workflow runs and a newer izgw-core release exists
- **THEN** the izgw-core version SHALL be unchanged

#### Scenario: Exclusions file missing
- **WHEN** the file named by `exclusions-file` does not exist
- **THEN** the workflow SHALL fail with an error naming the file, and SHALL NOT open a PR

### Requirement: No PR when nothing changes

When the update goals change no tracked file, the workflow SHALL NOT create a branch or PR, and SHALL write "No patch updates available" to the job summary.

#### Scenario: Everything current
- **WHEN** every project-owned version is already on its latest patch release
- **THEN** the run SHALL succeed with no PR and the summary SHALL say no patch updates are available

### Requirement: Verified bot commit

The workflow SHALL create the update commit through the Git Data API with the `izg-dependency-bot` App token and no author or committer, containing every changed tracked file, so that GitHub signs it.

#### Scenario: Commit identity
- **WHEN** the workflow opens a PR
- **THEN** its single commit SHALL have author `izg-dependency-bot[bot]`, committer `web-flow`, and a verified signature

### Requirement: Branch naming and PR

The branch SHALL be `<branch-prefix>/nightly-<UTC timestamp>-<run id>-<attempt>` when `auto-merge` is true and `<branch-prefix>/manual-...` otherwise. The PR SHALL target `base-branch`, carry `pr-labels`, and list each changed version (old and new), the excluded artifacts, and the diff.

#### Scenario: Nightly run
- **WHEN** the caller passes `auto-merge: true`
- **THEN** the PR branch SHALL start with `<branch-prefix>/nightly-` and the PR description SHALL say it will be merged automatically once CI passes

#### Scenario: Manual run
- **WHEN** the caller passes `auto-merge: false`
- **THEN** the PR branch SHALL start with `<branch-prefix>/manual-` and the PR description SHALL say it needs a human review

### Requirement: Superseded nightly PRs closed

After opening a nightly PR, the workflow SHALL close every other open PR into `base-branch` whose branch starts with `<branch-prefix>/nightly-`, with a comment linking the new PR, and delete its branch. It SHALL NOT close manual PRs.

#### Scenario: Older nightly PR open
- **GIVEN** an open PR from `security-updates/nightly-A`
- **WHEN** a later run opens a PR from `security-updates/nightly-B`
- **THEN** the PR from `nightly-A` SHALL be closed as superseded

### Requirement: Cancelled PR build re-run

After opening a PR, the workflow SHALL watch the caller's `ci-workflow` run for the PR head commit and re-run it if it completes as `cancelled` while the PR is open, at most `max-build-reruns` times, then fail with an error.

#### Scenario: Build displaced from the queue
- **WHEN** the PR's CI run is cancelled because a newer run took its place in the concurrency group
- **THEN** the workflow SHALL re-run it

#### Scenario: Build fails
- **WHEN** the PR's CI run completes as `failure`
- **THEN** the workflow SHALL NOT re-run it, and the PR SHALL stay open
