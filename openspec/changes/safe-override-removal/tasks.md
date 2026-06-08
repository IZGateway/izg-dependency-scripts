## 1. Scratch-tree infrastructure

- [x] 1.1 Add a helper that creates a scratch directory under `os.tmpdir()` (unique name, e.g. `izg-override-trial-<random>`) and returns its path
- [x] 1.2 Copy the consumer's `package.json` and `package-lock.json` into the scratch dir
- [x] 1.3 If a `.npmrc` is present in CWD, copy it into the scratch dir; do not copy parent or home `.npmrc`
- [x] 1.4 Add a cleanup helper that best-effort removes the scratch dir (recursive `rm -rf`) and wire it to run on normal exit and on uncaught errors
- [x] 1.5 Confirm that scratch setup does not write anything into the consumer's CWD (manual check during dev)

## 2. Trial-install primitive

- [x] 2.1 Add a function `runTrialInstall(scratchDir)` that shells out to `npm install --package-lock-only --ignore-scripts --no-audit --no-fund` with `cwd: scratchDir`
- [x] 2.2 Inherit `NPM_TOKEN` / `GITHUB_TOKEN` and other env vars from the parent process (default `child_process` behavior is fine; do not strip env)
- [x] 2.3 Capture stdout + stderr and the exit code; return a structured result `{ ok, stderr, durationMs }`
- [x] 2.4 Treat a non-zero exit code from npm as a non-throwing failure (`ok: false`) so the caller can classify the override as `skipped`
- [x] 2.5 Wrap the call in a sensible per-trial timeout (e.g., 120s) and report timeout as the same `ok: false` failure mode

## 3. Per-override evaluation loop

- [x] 3.1 Replace the existing `for (const [pkg, overrideVersion] of Object.entries(...))` block with one that accumulates decisions in an array `decisions = []` instead of mutating `package.json` mid-loop
- [x] 3.2 For each override entry, validate that the value is a string; if not (nested override form), classify as `skipped` with reason "non-string override value" and continue
- [x] 3.3 For each candidate override:
  - [x] 3.3.1 Create a fresh scratch tree (or reset the existing one) seeded with the consumer's current `package.json` + `package-lock.json` + `.npmrc`
  - [x] 3.3.2 Edit the scratch `package.json` to delete only the candidate override (leave every other override entry in place)
  - [x] 3.3.3 Run `runTrialInstall` against the scratch tree
  - [x] 3.3.4 If install failed, record `{ pkg, overrideVersion, outcome: 'skipped', reason: <stderr excerpt> }` and continue
  - [x] 3.3.5 If install succeeded, read the scratch `package-lock.json` and reuse `findAllResolvedVersions` to collect every resolved version of `pkg`
  - [x] 3.3.6 If no resolutions exist for `pkg` in the scratch lockfile, record `{ outcome: 'removed', reason: 'package no longer in dependency graph' }`
  - [x] 3.3.7 If every resolution satisfies `>= overrideVersion` (using `semver.satisfies`/`semver.gte` with the same error handling as today), record `{ outcome: 'removed', reason: 'natural resolution: <minResolved>' }`
  - [x] 3.3.8 Otherwise record `{ outcome: 'kept', reason: 'natural resolution would drop to <minResolved>' }`

## 4. Atomic mutation + reporting

- [x] 4.1 After the evaluation loop, apply only the `removed` decisions to a copy of the consumer's `package.json` in memory
- [x] 4.2 If any `overrides` entries were removed and the resulting `overrides` object is empty, delete the `overrides` key entirely
- [x] 4.3 Write the mutated `package.json` back to disk exactly once (with trailing newline, 2-space indent — match current formatting)
- [x] 4.4 If no `removed` decisions exist, do not touch `package.json` at all
- [x] 4.5 Print a per-override summary table at the end of the run in the format documented in design.md D7 (one line per override, fixed-width outcome column, parenthetical reason)

## 5. Exit codes

- [x] 5.1 If any pre-evaluation failure occurs (missing `package.json` / `package-lock.json`, JSON parse failure, scratch setup failure before any trial ran), exit with code `1`
- [x] 5.2 ~~If at least one override ended in `skipped`, exit with code `2` after writing the summary and any `removed` mutations~~ — **superseded by IGDD-2967 (PR #8):** a `skipped` outcome is a normal result and exits `0`; only genuine failure (task 5.1) exits non-zero. The dedicated `2` code caused false nightly-workflow failures in Configuration Console and Transform UI.
- [x] 5.3 Otherwise exit with code `0` (overrides removed, kept, or skipped are all clean `0` exits — see 5.2)
- [x] 5.4 Replace the current bare `process.exit(0)` early-return (when no overrides are present) with the new exit-code policy — empty `overrides` is still a clean `0` exit

## 6. Verification against the regression case

- [x] 6.1 In a scratch checkout of `IZGateway/izg-configuration-console` (at the commit prior to PR #521), re-add `"postcss": "8.5.15"` and `"ajv": "8.20.0"` to `overrides` if needed, run the updated `test-overrides.js`, and confirm both are classified `kept` — *postcss correctly `kept` (trial introduces `next/.../postcss@8.4.31` below floor); ajv correctly `removed` because debug-mode trial showed `node_modules/ajv` resolves to 8.20.0 with or without the override. The concern doc's speculation that ajv was at risk was disproved by the trial — its top-level resolution is the same with or without the override*
- [x] 6.2 In the same checkout, add a deliberately stale override (e.g., a package whose floor is already met by the natural resolution) and confirm it is classified `removed` — *Three real-world examples observed in the same run: `fast-uri@^3.1.2`, `http-proxy-agent@^7.0.2`, `qs@^6.15.2` all correctly classified `removed`*
- [x] 6.3 Simulate a registry failure (e.g., temporarily point `.npmrc` at an unreachable registry) and confirm the override is classified `skipped` and the script exits cleanly — *Verified with a synthetic fixture: stubbed `npm` exited non-zero with a simulated `ECONNREFUSED` stderr. Override was classified `skipped` (reason captured the npm stderr) and `package.json` was left untouched. **Note (IGDD-2967, PR #8):** this run originally asserted exit code `2`; under the two-state contract a `skipped` outcome now exits `0`.*
- [x] 6.4 Confirm that running the script twice in a row against the same tree produces the same `package.json` on the second run (idempotency) — *Two consecutive runs against `izg-configuration-console` produced byte-identical classifications and identical post-mutation `package.json`*
- [x] 6.5 Confirm `node_modules`, `package-lock.json`, and any other files in the consumer's CWD are unchanged after a run (only `package.json` is touched, and only when overrides were removed) — *Verified during live runs against `izg-configuration-console`; only `package.json` was modified*

## 7. Release

- [x] 7.1 Update `README.md` to describe the per-override outcomes and exit codes for `test-overrides.js` (keep the rest of the docs intact) — *tri-state outcomes documented; exit-code section revised to the two-state `0`/`1` contract under IGDD-2967 (PR #8)*
- [ ] 7.2 Open a PR with label `bump:minor` so `ci.yml` cuts the next minor on merge
- [ ] 7.3 After merge, verify `@izgateway/dependency-scripts@1.1.0` (or whichever minor is cut) lands on the registry and the floating `@v1` tag advances
- [ ] 7.4 After release, follow up with `IZGateway/izg-configuration-console`: re-add `"postcss": "8.5.15"` and `"ajv": "8.20.0"` to `overrides` if PR #521 has merged, and confirm the next nightly run reports them as `kept`
