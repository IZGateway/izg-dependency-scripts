# Copilot Instructions — izg-dependency-scripts

## What this repository is

Two distinct products live here:

1. **npm package `@izgateway/dependency-scripts`** — Node.js CLI scripts consumed by other
   IZGateway projects to manage npm dependency vulnerabilities (`fix-vulnerabilities`,
   `test-overrides`, `update-overrides`).

2. **Shared GitHub Actions** — Reusable CI/CD building blocks for IZGateway projects:
   - `.github/actions/cve-scan/` — OWASP Dependency Check composite action (in use today)
   - `.github/workflows/ecr-scan-report.yml` — AWS Inspector2 ECR scan reusable workflow
     *(in progress — see `openspec/changes/cve-scan-action/`)*

## Build and publish

```bash
npm ci                # install deps (semver is the only peer dep)
npm test              # no-op — there are currently no automated tests
```

Publishing is fully automated via `ci.yml`. **Do not run `npm publish` manually.**

- **Dev release:** open or push to any PR targeting `main` → publishes `X.Y.Z-dev` tagged `@dev`
- **Release:** merge a PR to `main` → bumps `package.json`, commits `[skip ci]` to main,
  publishes `@latest`, creates `vX.Y.Z` and `vX` tags

## Release / versioning conventions

- **Bump type** is read from a PR label: `bump:major`, `bump:minor`, or `bump:patch`.
  Default when no label is present: `patch`.
- Floating major tag (`vX`) is force-updated on every release.
- Callers should pin to `@vX` for stability or `@vX.Y.Z` for full reproducibility.
  `@main` tracks HEAD.
- Branching model: `feature → PR → main`. No `develop` or `release_v*` branches.

## Composite action — key constraints

`.github/actions/cve-scan/action.yml` is a **composite** action, not a reusable workflow.

- **Secrets cannot be read inside a composite action** — `${{ secrets.* }}` always evaluates
  to empty string with no warning. The three secrets (`OSS_INDEX_USERNAME`,
  `OSS_INDEX_PASSWORD`, `NVDAPIKEY`) must be forwarded as inputs by the calling workflow.
  Do not attempt to move them into the action body.
- `--disableCentral` is hardcoded and must never be exposed as an input. See README for the
  rationale.
- The action runs inside the **calling job's workspace** — no artifact round-trip needed to
  access built JARs.

## ECR scan workflow — in-progress CR

An active OpenSpec change (`cve-scan-action`) is adding:
- `.github/scripts/ecr-scan-report.sh` — calls AWS Inspector2, filters by release date,
  writes JSON/CSV/HTML using CDC naming (`YYYYMMDD_{pkg}_vX.Y.Z_InspectorScan.*`)
- `.github/workflows/ecr-scan-report.yml` — reusable workflow wrapping the script
- Per-service wiring in `izgw-hub`, `izg-configuration-console`, `izg-transformation-ui`,
  `izgw-transform`
- `dry_run` `workflow_dispatch` input in each service to skip the APHL push while still
  generating scan reports

**Prerequisites for ECR tasks (6.5–6.8):** services must first produce
`{version}-RELEASE-{run}` ECR tags (blocked on `cve-scan-tooling` CR,
[IGDD-2563](https://izgateway.atlassian.net/browse/IGDD-2563)).

Tasks 2.1–2.4 (CI publish workflow) and 4.1–4.5 (migrate calling projects) are next
in queue and have no blockers.

Refer to `openspec/changes/cve-scan-action/tasks.md` for the full checklist.

## Image architecture policy

All IZ Gateway container images are **single-arch AMD64 only**. Do not introduce
multi-arch (OCI image index) builds without explicit documented justification.
`ecr:BatchGetImage` is not in scope for the ECR scan IAM role.

## OpenSpec change management

This repo uses OpenSpec for all non-trivial changes. Before starting new work:

```bash
openspec list          # see active CRs
openspec show <name>   # read proposal, design, specs for a CR
openspec status        # artifact completion for current CR
```

CR artifacts live in `openspec/changes/<change-name>/`. The artifact order is:
`proposal.md` → `specs/<capability>/spec.md` → `design.md` → `tasks.md`.

## npm scripts package — key internals

- `fix-all-vulnerabilities.js` — reads `npm audit --json`, updates direct deps or adds
  `overrides` entries; respects `OVERRIDE_BLOCKLIST` (e.g., `immutable`) and
  `META_PACKAGES` (e.g., `typescript-eslint` sub-packages updated together).
- `test-overrides.js` — removes overrides that are no longer needed (resolved version
  already satisfies the override constraint).
- `update-overrides.js` — bumps existing overrides to latest same-major version from the
  npm registry.
- Scripts use `semver` (peer dependency) for version comparisons.
- In CI, invoke via `node node_modules/@izgateway/dependency-scripts/<script>.js` — do not
  rely on the bin symlinks inside Actions runners.

## GitHub Packages authentication

The package is published to and consumed from GitHub Packages (`npm.pkg.github.com`).
The `.npmrc` in this repo uses `${NPM_TOKEN}` for local dev; CI uses `GITHUB_TOKEN`.
Consumers must have `@izgateway:registry=https://npm.pkg.github.com` in their `.npmrc`.
