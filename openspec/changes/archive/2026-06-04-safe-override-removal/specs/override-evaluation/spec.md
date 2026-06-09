# Spec: override-evaluation

Capability for evaluating whether each entry in a consumer's `package.json`
`overrides` block is still required, and for safely removing only those that are
genuinely redundant.

## ADDED Requirements

### Requirement: Removal decisions SHALL be based on natural resolution, not on the active lockfile

The script SHALL determine whether an override is still required by observing what
npm would resolve **in the absence of that override**, not by inspecting versions
already resolved in `package-lock.json` while the override is active.

The script SHALL compare resolutions **per dependency-graph path**, considering both
the trial (override-removed) lockfile and the consumer's current (override-active)
lockfile. An override counts as still required (and SHALL be `kept`) if removing it
causes a **regression**, defined as any of:

- A path that exists in both lockfiles, whose **current** version was at or above the
  override floor and whose **trial** version is below the floor;
- A **new** path introduced in the trial (absent in the current lockfile, i.e., the
  override was preventing that path's existence) whose trial version is below the floor; **or**
- A **disappeared** path — a path whose current version was at or above the floor
  but is absent in the trial lockfile — **when** the trial lockfile still contains at
  least one below-floor instance of the package elsewhere. This catches the case
  where removing the override causes npm to deduplicate consumers of the package
  down to a low-version path that was previously coexisting (e.g., a nested-override
  path at a lower major).

Paths whose current version is already below the floor (because of another override
or intentional pinning by a parent dependency) are **not** treated as regressions —
those paths were not what this override was protecting. A disappeared at-or-above-floor
path with **no** below-floor remnants in the trial is also not a regression — the
consumers there either dropped the dependency entirely or moved to other at-or-above-floor
instances.

#### Scenario: Exact-pin override is preserved when natural resolution would drop below the floor

- **WHEN** a consumer's `package.json` contains `"overrides": { "postcss": "8.5.15" }`
  and at least one path where `postcss` currently resolves at or above `8.5.15`
  would resolve below `8.5.15` in the trial lockfile
- **THEN** the script SHALL keep the override in `package.json` and SHALL classify it
  as `kept` in its per-override report

#### Scenario: Override is removed when no path regresses

- **WHEN** a consumer's `package.json` contains an override and, for every path where
  the overridden package resolves in the trial lockfile, either the trial version is
  at or above the override floor or the same path was already below the floor in the
  current lockfile
- **THEN** the script SHALL remove the override from `package.json` and SHALL classify
  it as `removed` in its per-override report

#### Scenario: Coexisting nested override does not cause false `kept`

- **WHEN** a consumer's `package.json` contains both a top-level override `"ajv": "8.20.0"`
  and a nested override `"eslint": { "ajv": "^6.14.0" }`, and the trial removes only the
  top-level override
- **THEN** the script SHALL NOT count the eslint-nested `ajv@6.x` path as a regression
  (it was already below `8.20.0` in the current lockfile by design), and the script
  SHALL classify the top-level `ajv` override as `kept` only if some **other** path
  where `ajv` was at or above `8.20.0` would regress in the trial

#### Scenario: Dedup-down disappearance is caught as a regression

- **WHEN** the consumer's current lockfile has a path where the overridden package
  resolves at or above the floor (e.g., `node_modules/ajv: 8.20.0`), and the trial
  lockfile lacks that path entirely while still containing at least one below-floor
  instance of the package (e.g., a nested-override `node_modules/eslint/node_modules/ajv: 6.15.0`)
- **THEN** the script SHALL classify the override as `kept`, recognizing that the
  protected path's consumers have likely been deduplicated to the below-floor instance

#### Scenario: Lockfile-only inspection is insufficient

- **WHEN** the lockfile shows every resolution of an overridden package at exactly the
  override version
- **THEN** the script SHALL NOT treat that as evidence the override is redundant; it
  SHALL still perform a natural-resolution check before considering removal

### Requirement: Each override SHALL receive a tri-state outcome

For every entry in `package.json` `overrides`, the script SHALL produce exactly one
of three outcomes and SHALL print that outcome alongside the package name and the
override version:

- `kept` — natural-resolution check showed the override is still required.
- `removed` — natural-resolution check showed the override is no longer required.
- `skipped` — the natural-resolution check could not be completed (e.g., npm command
  failure, lockfile parse failure, network/registry failure).

#### Scenario: Outcome is reported per override

- **WHEN** the script finishes evaluating all overrides
- **THEN** the script's output SHALL include one line per override identifying the
  package name, the override version, and the outcome (`kept` / `removed` / `skipped`)

#### Scenario: Skipped outcome defaults to keeping the override

- **WHEN** the natural-resolution check for an override cannot be completed for any reason
- **THEN** the override SHALL remain in `package.json` and the outcome SHALL be reported
  as `skipped`

### Requirement: Exit codes SHALL distinguish completion from failure

The script's process exit code SHALL convey one of two states so that calling
workflows can react appropriately:

- **`0`** — evaluation completed. Overrides may have been removed, kept, or skipped;
  all three are normal outcomes. A `skipped` override is **not** an error and does
  not affect the exit code.
- **`1`** — genuine failure before or during evaluation: missing or unparseable
  `package.json` / `package-lock.json`, scratch-tree setup failure, or an uncaught
  exception.

Callers detect whether `package.json` changed via `git diff` (the same contract
used by `update-overrides` and `fix-vulnerabilities`); they SHALL invoke this script
without an error guard and expect `0` on any successful run.

> **Superseded by IGDD-2967 (PR #8).** The original design specified a tri-state
> exit code with a dedicated "evaluation incomplete" code (`2`) for runs with at
> least one `skipped` override. That distinction caused nightly workflow failures
> in consumer repos (Configuration Console and Transform UI), because a `skipped`
> outcome is a routine, non-fatal result rather than an error. The contract above
> is the current two-state behavior: `0` for any completed evaluation and `1` for
> genuine failure.

#### Scenario: Completed run, regardless of per-override outcomes

- **WHEN** the script evaluates every override and each ends in `kept`, `removed`,
  or `skipped`
- **THEN** the script SHALL exit with code `0`

#### Scenario: Pre-evaluation or in-evaluation failure

- **WHEN** the script cannot begin or complete evaluation because `package.json` or
  `package-lock.json` is missing or malformed, scratch setup fails, or an uncaught
  exception is raised
- **THEN** the script SHALL exit with code `1`

### Requirement: Mutation of `package.json` SHALL be atomic across the run

The script SHALL apply changes to the consumer's `package.json` only after all
overrides have been evaluated. A failure or `skipped` outcome partway through
SHALL NOT leave the file in a half-mutated state.

#### Scenario: Atomic write after full evaluation

- **WHEN** the script has finished evaluating all overrides and at least one was
  classified `removed`
- **THEN** the script SHALL write `package.json` exactly once, with all `removed`
  overrides deleted and all `kept`/`skipped` overrides untouched

#### Scenario: No overrides removed means no write

- **WHEN** no overrides were classified `removed`
- **THEN** the script SHALL NOT modify `package.json`

### Requirement: Natural-resolution check SHALL NOT modify the consumer's working tree

Any side effects required to compute the natural resolution (file copies, scratch
installs, temporary `node_modules`, temporary lockfiles) SHALL occur outside the
consumer's working directory. The consumer's `node_modules`, `package-lock.json`,
and other working-tree files SHALL be unchanged by the evaluation itself; the
only file the script writes inside the consumer's working tree is `package.json`,
and only when overrides were classified `removed`.

#### Scenario: Scratch artifacts are isolated

- **WHEN** the script performs a natural-resolution check
- **THEN** any temporary files or installs created for that check SHALL reside in
  a scratch location (e.g., the OS temp directory), not in the consumer's working
  tree, and SHALL be cleaned up before the script exits

#### Scenario: Lockfile is untouched by evaluation

- **WHEN** the script finishes a run in which one or more overrides were classified
  `removed`
- **THEN** the consumer's `package-lock.json` SHALL be unchanged; regenerating it
  is the caller's responsibility (typically via a follow-up `npm install`)

### Requirement: Consumer override schema SHALL remain unchanged

The script SHALL continue to operate on the existing npm `overrides` object as
documented by npm. It SHALL NOT require consumers to adopt a richer schema (such
as paired justification files, CVE-reference annotations, or structured comments)
in order to evaluate or remove overrides.

#### Scenario: Plain npm overrides remain supported

- **WHEN** a consumer's `package.json` uses standard npm `overrides` syntax (a flat
  object of `"package": "version"` entries)
- **THEN** the script SHALL evaluate and act on those overrides without requiring
  any additional metadata

### Requirement: Package not present in the dependency graph SHALL be classified `removed`

If an override targets a package that is not present anywhere in the consumer's
natural dependency graph (i.e., no dependent declares it directly or transitively),
the override is dead weight and SHALL be classified `removed`.

#### Scenario: Override for a package that no dependency requires

- **WHEN** an override targets a package that does not appear in the natural
  resolution at all (the consumer no longer depends on it through any path)
- **THEN** the script SHALL classify the override as `removed` and SHALL delete it
  from `package.json`

### Requirement: Empty `overrides` after removal SHALL be cleaned up

When the script removes the last entry from the `overrides` object, it SHALL
delete the empty `overrides` key from `package.json` rather than leaving an
empty object behind.

#### Scenario: Last remaining override is removed

- **WHEN** the script removes the only entry in `overrides`
- **THEN** the resulting `package.json` SHALL NOT contain an `overrides` key
