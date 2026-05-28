# Spec: security-updates-workflow

## Purpose

Reusable `workflow_call` workflow that centralizes the entire security update process
— ncu, override updates, vulnerability fixes, build/test, PR creation, and
`security update` label application — replacing the copy-pasted `security-updates.yml`
in each consuming project.

## Requirements

### Requirement: Workflow Triggers

The workflow supports two triggers:

- `workflow_call` — invoked by a consuming project's thin caller.
- `workflow_dispatch` — manual trigger directly on `izg-dependency-scripts` for testing.

#### Scenario: Called via workflow_call from consuming project
WHEN a consuming project's scheduled or dispatched workflow calls this workflow via
`workflow_call`<br>
THEN all inputs and secrets are forwarded from the caller and the full update sequence
runs in the context of the consuming project's repository.

#### Scenario: Triggered via workflow_dispatch directly
WHEN a developer triggers the workflow manually on `izg-dependency-scripts`<br>
AND supplies a `target-repository` input<br>
THEN the workflow runs against that repository using the provided token.

---

### Requirement: Workflow Inputs

The workflow exposes all project-specific values as inputs so the caller controls
project behavior without forking the workflow logic.

| Input | Type | Required | Default | Description |
|---|---|---|---|---|
| `base-branch` | string | no | `develop` | Branch the PR targets |
| `dependency-scripts-channel` | choice (`latest`, `dev`) | no | `latest` | npm tag for `@izgateway/dependency-scripts` |
| `quality-check-command` | string | no | `npm run code-quality-check` | Command to run code quality checks |
| `test-command` | string | no | `npm run test` | Command to run tests |
| `build-command` | string | no | `npm run build` | Command to build the application |
| `node-version` | string | no | `22` | Node.js version |

Required secrets (caller must pass):
- `NPM_TOKEN` — authenticates `@izgateway` GitHub Packages scope.
- `IZGW_ALL_REPO_ACCESS_TOKEN` — token used for `gh pr create`; must have `contents: write` and `pull-requests: write` on the consuming repository.

#### Scenario: Caller provides custom test command
WHEN a consuming project sets `test-command: "npm run test:ci"`<br>
THEN the workflow runs `npm run test:ci` at the test step instead of the default.

#### Scenario: Caller omits optional inputs
WHEN a consuming project does not supply optional inputs<br>
THEN all defaults apply and the workflow behaves identically to the original
copy-pasted `security-updates.yml` in that project.

---

### Requirement: Dependency Update Sequence

The workflow runs the following steps in order when invoked:

1. **Checkout** — using `IZGW_ALL_REPO_ACCESS_TOKEN` (not `GITHUB_TOKEN`) so the
   subsequent `gh pr create` can label the PR.
2. **Setup Node.js** — version from `node-version` input; cache npm; configure
   `@izgateway` registry.
3. **Configure Git** — `github-actions[bot]` identity.
4. **Configure npm auth** — `@izgateway:registry` to GitHub Packages using `NPM_TOKEN`.
5. **Install dependencies** — `npm ci && npm audit fix || true`.
6. **Install security tooling** — `npm-check-updates` globally; `@izgateway/dependency-scripts`
   at the channel specified by `dependency-scripts-channel`.
7. **Run ncu** — `ncu --target minor --reject "@typescript-eslint/*" -u`; capture
   `has_ncu_changes` output.
8. **Update overrides** — `update-overrides.js`; capture `has_override_changes` output.
9. **Fix vulnerabilities** — `fix-all-vulnerabilities.js`; capture `has_security_changes`
   output.
10. **Check for changes** — if none of the three change flags are `true`, write a
    "no updates" step summary and exit cleanly (no PR created).
11. **Create branch** — `automated-security-updates-YYYYMMDD-HHMMSS`.
12. **Test override removal** — `test-overrides.js`.
13. **Commit** — `npm install && npm audit fix`; commit `package.json` and
    `package-lock.json` with the standard commit message.
14. **Quality check** — `quality-check-command` input.
15. **Tests** — `test-command` input; `continue-on-error: true`.
16. **Build** — `build-command` input.
17. **Security audit** — `npm audit --audit-level=low`; warn if residual vulnerabilities.
18. **Generate PR body** — includes package diff, checklist, workflow run link.
19. **Push branch**.
20. **Create PR** — using `IZGW_ALL_REPO_ACCESS_TOKEN`; targets `base-branch` input;
    title `chore(deps): security and dependency updates`; applies label `security update`.
21. **Upload npm logs on failure** — `actions/upload-artifact@v4`; 7-day retention.

#### Scenario: No dependency changes found
WHEN all ncu, override, and vulnerability checks find nothing to change<br>
THEN no branch is created, no PR is opened, and the workflow exits with success after
writing a "No Dependency Updates Available" step summary.

#### Scenario: Changes found, all checks pass
WHEN at least one change is detected<br>
AND quality check, tests, and build all succeed<br>
THEN a PR is created targeting `base-branch`, carrying the `security update` label.

#### Scenario: Changes found, a check fails
WHEN a build or quality check step fails<br>
THEN the workflow fails, npm logs are uploaded as an artifact, and no PR is created.
> Note: `test-command` uses `continue-on-error: true` — test failures do not block PR creation but appear as warnings.

---

### Requirement: PR Label Application

The workflow ensures the `security update` label exists and applies it to the PR at
creation time. A dedicated step runs `gh label create` before `gh pr create`, using
`|| true` to make it idempotent — if the label already exists the step succeeds silently.

```bash
gh label create "security update" \
  --color "#2ea7e0" \
  --description "Automated security dependency update PR" || true
```

This eliminates label creation as a manual migration prerequisite.

#### Scenario: Label does not yet exist
WHEN the workflow runs for the first time in a consuming repository<br>
AND the `security update` label does not exist<br>
THEN `gh label create` creates it; `gh pr create --label "security update"` succeeds.

#### Scenario: Label already exists
WHEN the workflow runs and the `security update` label already exists<br>
THEN `gh label create ... || true` exits successfully without error; `gh pr create`
applies the existing label.
