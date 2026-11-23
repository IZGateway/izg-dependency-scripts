# Spec: bot-pr-actions

This capability covers the composite actions that `maven-security-updates` and `security-update-auto-merge` are built from. Each action is usable on its own. Behaviour of the workflows is specified in their own specs; this spec covers the action boundaries.

## ADDED Requirements

### Requirement: Credentials are inputs

No action SHALL read `secrets.*` or contain a default credential. Each action that needs a token or key SHALL take it as an input and SHALL fail with an error naming the input when a required credential is empty.

#### Scenario: Token missing
- **WHEN** `setup-izg-maven` is called with an empty `github-token`
- **THEN** it SHALL fail with an error naming `github-token`, before writing `settings.xml`

### Requirement: setup-izg-maven

The action SHALL set up the requested JDK and Maven versions and write `~/.m2/settings.xml` with one `<server>` entry per id in `maven-servers`, using the caller's `github-token`.

#### Scenario: Several GitHub Packages repositories
- **WHEN** called with `maven-servers: github-bom github-core v2tofhir`
- **THEN** `settings.xml` SHALL contain a server entry for each of the three ids

### Requirement: maven-patch-updates changes files only

The action SHALL apply patch updates and write the PR description, and SHALL NOT commit, push or open a PR. It SHALL set the output `has-changes` to `true` or `false`.

#### Scenario: Nothing to update
- **WHEN** no project-owned version has a newer patch release
- **THEN** `has-changes` SHALL be `false`, no verify command SHALL run, and the job summary SHALL say no patch updates are available

### Requirement: open-signed-pr

The action SHALL commit every modified tracked file through the Git Data API with the given token and no author or committer, create the branch, and open the PR. It SHALL fail when there are no modified tracked files or the description file is missing. It SHALL close older open nightly PRs only when the new PR is a nightly PR.

#### Scenario: Manual run with an open nightly PR
- **GIVEN** an open PR from `security-updates/nightly-A`
- **WHEN** the action opens a PR with `auto-merge: false`
- **THEN** the nightly PR SHALL stay open

### Requirement: rerun-cancelled-build

The action SHALL re-run the CI run for the given branch and head commit only when it completes as `cancelled` while the PR is open, at most `max-reruns` times, then fail.

#### Scenario: Run succeeds
- **WHEN** the CI run completes as `success`
- **THEN** the action SHALL exit successfully with output `conclusion` set to `success` and SHALL NOT re-run it

### Requirement: auto-merge-bot-pr fails closed

The action SHALL itself check eligibility (pull_request event, base branch, same repository, PR author, branch prefix) and SHALL refuse with an error, without approving or merging, when any eligibility, provenance or content check fails. It SHALL NOT rely on the caller's job-level `if:`.

#### Scenario: Called for a developer's PR
- **WHEN** the action runs on a PR opened by a developer
- **THEN** it SHALL fail with "Auto-merge refused: PR was opened by ..." and SHALL NOT approve or merge
