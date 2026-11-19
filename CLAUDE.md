---
schema_version: '1.0'
created:
  date: '2026-11-19T19:14:21.019Z'
  user: boonek
  agent:
    name: claude-code
    version: unknown
  llm:
    name: claude-sonnet-5-5
    version: '5.5'
  prompt_uri: >-
    prompt:/claude-code/e97707d1-5a7a-43cc-bd06-e16a2398b7dc/~53d6c0a0-06b7-448f-8e0c-937dbe7903c1
  summary: Initial CLAUDE.md created via /init
updated: []
---
# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Two products live here (this repo is **public**; see the IZ Gateway Public Repo Policy in `~/.claude/CLAUDE.md`):

1. **npm package `@izgateway/dependency-scripts`**: CLI scripts at the repo root that other IZ Gateway JS repos use for CVE remediation. Published to GitHub Packages. Bins: `fix-vulnerabilities` (`fix-all-vulnerabilities.js`), `test-overrides`, `update-overrides`. `semver` is a peer dependency; plain CommonJS, no build step.
2. **Shared GitHub Actions** consumed by other IZ Gateway repos:
   - `.github/actions/cve-scan/`: composite action wrapping OWASP Dependency Check.
   - `.github/workflows/ecr-scan-report.yml`: reusable workflow (`workflow_call`) that runs `.github/scripts/ecr-scan-report.sh` (plus `.jq` filters) to pull AWS Inspector2 findings for an ECR image and emit JSON/CSV/HTML reports.

The `migrate-to-package.*`, `update-dependencies.*`, `publish.cmd` and `SETUP.md` files are helper/legacy material for consumers; `publish.cmd` is not how releases happen.

## Commands

- `npm ci`: install. `npm test` is a no-op (`No tests specified`); the package scripts have no automated tests.
- Run a script against a consumer project: `node <path>/fix-all-vulnerabilities.js` from that project's root (the scripts read `package.json`/`package-lock.json` and run `npm audit`/`npm install` in the **cwd**). In CI, call via `node node_modules/@izgateway/dependency-scripts/<script>.js` rather than the bin symlinks.
- ECR scan report tests (the only automated tests; need `jq`, no AWS creds, use fixtures): `bash .github/scripts/test/run-tests.sh`
- Workflow lint: CI runs `actionlint` (`validate.yml`) on PRs and pushes to main.

## Release process (do not `npm publish` manually)

`ci.yml`, branching model `feature -> PR -> main` only (no develop/release branches):
- PR opened/pushed/labeled against `main`: publishes `X.Y.Z-dev.<run>` under the `@dev` tag, no commit.
- PR merged: bumps `package.json`, commits `chore: release vX.Y.Z [skip ci]` to main, publishes `@latest`, tags `vX.Y.Z` and force-moves floating `vX`.
- Bump type comes from the PR label `bump:major|minor|patch` (default `patch`). Do not hand-bump `package.json` `version` on a feature branch.
- Consumers pin `@vX` (stability), `@vX.Y.Z` (reproducible), or `@main` (HEAD).

## Architecture notes (non-obvious)

**Override lifecycle.** The three scripts form a pipeline run by consumers' security-update workflows: `ncu --target minor` -> `update-overrides` -> `fix-vulnerabilities` -> `test-overrides` -> `npm install`. Callers detect changes with `git diff` on `package.json`, so scripts must exit `0` on any successful evaluation (including "nothing changed", `kept`, `skipped`) and `1` only on genuine failure.

- `fix-all-vulnerabilities.js`: parses `npm audit --json`; for each vulnerable package either bumps the direct dependency (same major) or adds an `overrides` entry. `OVERRIDE_BLOCKLIST` (packages needing manual review, e.g. `immutable`) and `META_PACKAGES` (e.g. `typescript-eslint` sub-packages, updated together, or overridden when only one sub-package is direct) encode special cases; `wouldDowngrade()` guards meta-package handling against downgrades (IGDD-3645).
- `test-overrides.js`: trial-removes each override in a scratch copy of the tree under `os.tmpdir()`, runs `npm install --package-lock-only`, and keeps the override only if the natural resolution would fall below its floor. Outcomes are `kept` / `removed` / `skipped`. Only `package.json` in the real tree is ever modified. Behavior is specified in `openspec/specs/override-evaluation/`.
- `update-overrides.js`: bumps existing overrides to the latest same-major version from the registry.

**Composite action constraints** (`cve-scan`):
- `${{ secrets.* }}` evaluates to empty string inside a composite action with no warning, so `OSS_INDEX_USERNAME`, `OSS_INDEX_PASSWORD`, `NVDAPIKEY` must be passed in as inputs by the caller. Do not move them into the action body.
- `--disableCentral` is hardcoded and must never become an input (rationale in README).
- Composite actions run in the caller's workspace, so no artifact round-trip is needed to reach built JARs.

**ECR scan report.** Output files use the CDC naming convention `YYYYMMDD_{pkg}_vX.Y.Z_InspectorScan.{json,csv,html}`; findings are filtered to `vendorCreatedAt <= release-date`. The job is `continue-on-error` and must never block a release. The caller needs `AWS_ROLE_ARN` (OIDC) with `inspector2:ListFindings`. Services must produce `{version}-RELEASE-{run}` ECR tags. All images are single-arch AMD64; do not add multi-arch builds.

## OpenSpec and docs

Non-trivial work goes through OpenSpec (`openspec list`, `openspec show <name>`, `openspec status`). Active CRs: `cve-scan-action` (ECR scan workflow rollout; its `tasks.md` is the authoritative checklist) and `fix-ecr-scan-arg-list-overflow`. `.claude/skills/`, `.claude/commands/opsx/` and `.github/skills/` hold copies of the standard `openspec-*` skills. `.github/copilot-instructions.md` covers much of the same ground as this file.

Package auth: the package lives on `npm.pkg.github.com`; consumers need `@izgateway:registry=https://npm.pkg.github.com` in `.npmrc`. Local `.npmrc` uses `${NPM_TOKEN}`, CI uses `GITHUB_TOKEN`.
