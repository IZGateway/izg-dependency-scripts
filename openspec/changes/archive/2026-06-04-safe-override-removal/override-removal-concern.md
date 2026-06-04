# Concern: `test-overrides.js` may remove overrides that are still required

## Summary

The override-removal step in `@izgateway/dependency-scripts` (`test-overrides.js`) decides whether an override is still needed by comparing the override version against the resolved versions in `package-lock.json`. There's a subtle interaction worth revisiting: the lockfile already reflects the override that's being evaluated, so an exact-pin override can appear redundant — even in cases where removing it would let npm resolve a lower, vulnerable version through a transitive dependency.

We observed this in `IZGateway/izg-configuration-console` PR #521, where the `postcss: "8.5.15"` override was removed by the nightly security-updates workflow. After removal, npm resolved a lower `postcss` version through a transitive dependency, and our SCA scan picked up a medium-severity CVE that the override had previously been suppressing.

## Reproduction context

- Consumer repo: `IZGateway/izg-configuration-console`
- Tool: `@izgateway/dependency-scripts@1.0.3`, file `test-overrides.js`
- Workflow: `.github/workflows/security-updates.yml` (steps "Test override removal" then "Commit changes")
- Affected PR: `IZGateway/izg-configuration-console#521`
- The same scenario likely applies to other exact-pin overrides in this repo (e.g. `ajv: "8.20.0"`).

## What we're seeing

In `test-overrides.js`, for each entry in `package.json` `overrides`, the script:

1. Reads every resolved version of that package from `package-lock.json`.
2. Asks: "Are *all* resolved versions `>=` the override version (or equal to it)?"
3. If yes, removes the override from `package.json`.

The subtlety: while an override is active, npm has already pinned every transitive resolution to the override's version. So the lockfile shows every `postcss` entry as `8.5.15`, and every entry naturally satisfies `>=8.5.15`. From the lockfile's perspective the override looks like it isn't changing anything — but in this case it's the reason those resolutions are at that version in the first place.

The consuming workflow then runs `npm install` (which re-resolves without the override, picking up a lower version) followed by `npm audit fix || true`. Because the only available repair would be a breaking change, `audit fix` can't correct it automatically, and the workflow commits and opens a PR that has unintentionally weakened the security posture.

## Expected behavior

We'd like the script to only remove an override when removing it does not reintroduce a vulnerability or drop a resolved version below a known-safe floor.

Detecting "is this override still required?" likely needs to observe what npm would resolve *in the absence of the override*, rather than what it has already resolved while the override is in place.

## Suggested approaches (non-prescriptive)

A few possible directions, in rough order of rigor:

1. **Trial-removal in a scratch tree.** Copy `package.json` + `package-lock.json` to a temp directory, remove the candidate override, run `npm install`, then run `npm audit --json`. If new vulnerabilities appear (or any resolved version drops below the previous override floor), keep the override. Doing this one override at a time keeps failures attributable.
2. **Compare against the natural resolution.** Compute what each parent dependency's semver range would allow without the override, and only remove if the minimum of that natural range is already `>=` the override floor. Avoids running `npm install` but requires resolving semver ranges from the lock data.
3. **Pair every override with an explicit justification.** Have overrides carry an associated minimum-safe version or CVE reference (e.g. a sibling JSON file or a structured comment). Compare resolved versions against that documented floor rather than the override version itself. Removes the ambiguity but requires a schema change in the consumer repos.

Option 1 is the most direct match for what a human reviewer would do, and it also catches the case where an override is masking a vulnerability that npm's resolver wouldn't fix on its own.

## Acceptance criteria for a fix

- Running `test-overrides.js` against `IZGateway/izg-configuration-console`'s current `package.json` does not remove `postcss: "8.5.15"` while npm would otherwise resolve a `postcss` version below `8.5.15` for any transitive dependent.
- The same holds for `ajv: "8.20.0"` and any other exact-pin override currently in that `overrides` block where removal would lower a resolved version.
- An override that is genuinely redundant (e.g. all parents have published new majors with safe ranges) is still removed.
- The script reports, per override, which of these three outcomes occurred: kept (still required), removed (no longer required), or skipped (could not determine — defaulting to keep).
- The script's exit code distinguishes "no removals" from "evaluation could not be completed," so a calling workflow can treat the latter as non-fatal but visible.

## Out of scope

- Changes to the consumer workflow (`security-updates.yml`) — once the script's removal logic is updated, the workflow's existing `npm install` + audit step should be fine.
- The `fix-all-vulnerabilities.js` path (separate concern; this writeup is only about removal logic).
- Promoting overrides to a richer schema; mentioned as an option but not required for a minimum fix.

## References

- Source under discussion: `test-overrides.js` in `IZGateway/izg-dependency-scripts` (published as `@izgateway/dependency-scripts`).
- Consumer evidence: `IZGateway/izg-configuration-console` PR #521 (diff removes `"postcss": "8.5.15"` from `overrides`).
- Workflow that runs the script nightly: `.github/workflows/security-updates.yml` in the consumer repo, step "Test override removal".
