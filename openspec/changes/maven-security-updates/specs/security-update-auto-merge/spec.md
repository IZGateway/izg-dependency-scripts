# Spec: security-update-auto-merge

This capability covers the reusable workflow `.github/workflows/auto-merge-security-update.yml`, which approves and merges the bot's security-update PR after the caller's CI build passes.

## ADDED Requirements

### Requirement: Runs only after the build passes

Callers SHALL invoke the workflow from their CI workflow as a job with `needs:` on the build job, so it starts only when the build, tests and deploy succeed.

#### Scenario: Build fails
- **WHEN** the PR's build job fails
- **THEN** the auto-merge job SHALL NOT run and the PR SHALL stay open

### Requirement: Only the bot's own update PRs qualify

The job SHALL run only for `pull_request` events into `base-branch`, from the same repository, opened by `bot-login`, from a branch starting with `branch-prefix`. For every other PR it SHALL be skipped.

#### Scenario: Developer's PR
- **WHEN** a developer's PR passes its build
- **THEN** the auto-merge job SHALL be skipped

#### Scenario: Manual-run update PR
- **WHEN** a bot PR from `security-updates/manual-*` passes its build
- **THEN** the auto-merge job SHALL be skipped

### Requirement: Provenance check

Before approving, the workflow SHALL read the repository activity log for the PR branch and SHALL refuse the merge, with an error, if there is no activity, if any actor other than `bot-login` wrote to the branch, if the branch was force-pushed, or if the last write's resulting commit is not the PR head commit that CI tested.

#### Scenario: Someone else pushed to the bot's branch
- **WHEN** a developer pushes a commit to a `security-updates/nightly-*` branch and its build passes
- **THEN** the workflow SHALL refuse the merge, naming the other actor

### Requirement: Content check

The workflow SHALL refuse the merge, with an error, unless every changed file path matches `allowed-files` and every commit's author, committer and verification are exactly `<bot-login>`, `web-flow` and `true`.

#### Scenario: Extra file changed
- **WHEN** the PR changes a file that does not match `allowed-files`
- **THEN** the workflow SHALL refuse the merge, naming the file

#### Scenario: Bot's signed commit
- **WHEN** the only commit is authored by `izg-dependency-bot[bot]`, committed by `web-flow`, and verified
- **THEN** the content check SHALL pass

### Requirement: Approve and merge

When both checks pass, `github-actions[bot]` SHALL approve the PR, and the workflow SHALL merge it with the bot's App token using `merge-method`, `--delete-branch` and `--match-head-commit` set to the tested head commit.

#### Scenario: All checks pass
- **WHEN** the build and both checks pass
- **THEN** the PR SHALL be approved by `github-actions[bot]`, merged by `izg-dependency-bot`, and its branch deleted, and the merge SHALL start the caller's CI on `base-branch`

#### Scenario: Head changed after the build
- **WHEN** the PR head moves after CI tested it
- **THEN** the merge SHALL fail rather than merge the untested commit
