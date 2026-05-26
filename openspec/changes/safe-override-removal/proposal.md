# Proposal: Safe Override Removal in `test-overrides.js`

## Date
2026-05-26

## Status
Proposed

## User Stories

**As an IZGateway developer**, I want the nightly security-updates workflow to only remove an npm
`overrides` entry when removing it would not let npm resolve a lower, vulnerable version through
a transitive dependency, so that automated PRs do not silently weaken our security posture by
deleting overrides that are still doing real work.

## Success Criteria

- **Given** `IZGateway/izg-configuration-console` has `"postcss": "8.5.15"` in `overrides`
  and at least one transitive dependent whose own semver range would resolve `postcss` below `8.5.15`,
  **When** the nightly security-updates workflow runs `test-overrides.js`,
  **Then** the override is **kept**, and the script's output explicitly reports it as `kept`
  with the natural-resolution version that would have been picked.
- **Given** an override is genuinely redundant (all parents have published majors whose ranges
  satisfy the override floor on their own),
  **When** `test-overrides.js` runs,
  **Then** the override is removed and reported as `removed`.
- **Given** the script cannot determine the natural resolution for an override (npm error,
  network failure, parse failure),
  **When** `test-overrides.js` runs,
  **Then** the override is **kept**, reported as `skipped`, and the script exits with a
  non-zero "evaluation incomplete" code that callers can distinguish from "no removals".

## Background

The override-removal step in `@izgateway/dependency-scripts` decides whether an `overrides`
entry is still needed by comparing the override version against the resolved versions in
`package-lock.json`. The subtle bug: the lockfile already reflects the override being
evaluated. When the override is an exact pin, every transitive resolution of that package
shows up at the override version, so the lockfile makes the override look redundant — even
when removing it would let npm resolve a lower, vulnerable version through a transitive
dependency.

This was observed in `IZGateway/izg-configuration-console` PR #521: the nightly workflow
removed `"postcss": "8.5.15"`, `npm install` re-resolved `postcss` to a lower version through
a transitive dependent, and SCA picked up a medium-severity CVE that the override had been
suppressing. The same risk applies to other exact-pin overrides in that repo (e.g.
`ajv: "8.20.0"`).

Full writeup of the failure mode, reproduction, and acceptance criteria from the consumer
side lives alongside this proposal in
[`override-removal-concern.md`](./override-removal-concern.md). It is the input document
that motivated this CR and is preserved with the change artifacts so the rationale travels
with the CR when it is archived.

## Why

`test-overrides.js` currently asks the lockfile a question whose answer is shaped by the
override itself — a feedback loop that makes exact-pin overrides appear unnecessary even
when they are the reason transitive resolutions are at safe versions. The fix is to evaluate
removal against what npm would resolve **in the absence of the override**, not against the
lockfile produced **with** the override active.

This needs fixing now because the nightly security-updates workflow runs against every
consumer of `@izgateway/dependency-scripts` and is actively producing PRs that delete
load-bearing overrides. Each merged PR is a silent regression that only surfaces when SCA
catches the reintroduced CVE — and only if SCA happens to flag that exact version.

## What Changes

- **Replace lockfile-only check** in `test-overrides.js` with a **trial-removal** strategy:
  for each override, copy `package.json` + `package-lock.json` to a temp working tree, remove
  the candidate override, run `npm install` (offline cache permitting), then re-read the
  resulting lockfile to determine what npm would resolve naturally. If any resolved version
  falls below the override floor, keep the override.
- **Report a tri-state outcome per override**: `kept` (trial showed it is still required),
  `removed` (trial showed natural resolution already meets the floor), or `skipped` (trial
  could not be completed — default to keeping the override).
- **Distinguish exit codes**: `0` for clean run with deterministic results (even if some
  overrides were kept); a distinct non-zero code (e.g. `2`) for "evaluation incomplete"
  (one or more overrides ended in `skipped` state) so calling workflows can treat that as
  visible-but-non-fatal.
- **Preserve current contract**: the script still mutates the consumer's `package.json` in
  place and still assumes the caller runs `npm install` afterward. No change to the bin
  symlink names, no change to peer-dep declarations.
- **No schema change to overrides themselves**: the proposed "pair every override with a
  justification" approach from the concern doc is out of scope for this CR (would require
  coordinated changes across every consumer repo).

## Capabilities

### New Capabilities
- `override-evaluation`: Determines whether each entry in a consumer's `package.json`
  `overrides` block is still required, by simulating removal in a scratch working tree
  and comparing the resulting natural resolution against the override floor. Reports
  per-override tri-state outcomes and uses exit codes to distinguish "no removals" from
  "evaluation incomplete."

### Modified Capabilities
<!-- None. There are no pre-existing specs in openspec/specs/ — test-overrides.js has
     never been spec'd before. This CR introduces the first spec for it. -->

## Impact

**Code:**
- `test-overrides.js` — substantial rewrite of the removal-decision logic. Lockfile
  traversal helpers (`findAllResolvedVersions`) become a fallback diagnostic at most;
  the primary signal is the result of trial `npm install` runs.
- Likely new internal helpers for: managing a temp scratch tree, invoking `npm install`
  there safely, parsing the resulting lockfile, and rolling per-override decisions up
  into the summary report.

**Behavior in consumer repos:**
- `IZGateway/izg-configuration-console`'s nightly `security-updates.yml` will start
  reporting `postcss` and `ajv` overrides as `kept` instead of removing them. No
  workflow change required on the consumer side — once the script's logic is fixed,
  the existing `npm install` + `npm audit fix` step still works.
- Runtime cost increases: trial `npm install` per override is slower than the current
  lockfile-only check. For repos with many overrides this may add minutes to the
  nightly job; acceptable trade-off given the security impact.

**APIs / dependencies:**
- No new runtime npm dependencies expected (uses existing `semver` peer dep, `fs`,
  `child_process.execSync`, and `os.tmpdir()`).
- No changes to peer-dep declarations or to the `bin` mapping in `package.json`.
- No changes to the release pipeline — published the usual way via `ci.yml` on merge to `main`.

**Release coordination:**
- A `bump:minor` is appropriate (behavior change, no breaking API change for consumers).
  Consumers pinned to `@v1` will pick up the fix automatically; those pinned to a full
  `@v1.0.3` will need to bump.
