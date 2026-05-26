# Spec: override-evaluation

Capability for evaluating whether each entry in a consumer's `package.json`
`overrides` block is still required, and for safely removing only those that are
genuinely redundant.

## ADDED Requirements

### Requirement: Removal decisions SHALL be based on natural resolution, not on the active lockfile

The script SHALL determine whether an override is still required by observing what
npm would resolve **in the absence of that override**, not by inspecting versions
already resolved in `package-lock.json` while the override is active. An override
SHALL only be considered removable when the natural-resolution version (the version
npm would pick with the override removed) is greater than or equal to the override
version for every transitive resolution in the dependency graph.

#### Scenario: Exact-pin override is preserved when natural resolution would drop below the floor

- **WHEN** a consumer's `package.json` contains `"overrides": { "postcss": "8.5.15" }`
  and at least one transitive dependent's semver range would otherwise resolve `postcss`
  below `8.5.15`
- **THEN** the script SHALL keep the override in `package.json` and SHALL classify it
  as `kept` in its per-override report

#### Scenario: Override is removed when natural resolution already satisfies the floor

- **WHEN** a consumer's `package.json` contains an override whose natural-resolution
  version (with the override removed) is already `>=` the override version for every
  resolution of that package
- **THEN** the script SHALL remove the override from `package.json` and SHALL classify
  it as `removed` in its per-override report

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

### Requirement: Exit codes SHALL distinguish completion states

The script's process exit code SHALL convey one of three completion states so that
calling workflows can react appropriately:

- **`0`** — evaluation completed for every override; results are deterministic.
  Applies whether some, all, or no overrides were removed.
- A distinct **non-zero "evaluation incomplete" code** (e.g., `2`) — at least one
  override ended in `skipped` state. Calling workflows SHOULD treat this as
  visible-but-non-fatal.
- Any other non-zero code — unrecoverable error before evaluation began
  (missing files, malformed `package.json`, etc.).

#### Scenario: Clean run with all overrides classified

- **WHEN** the script evaluates every override and each ends in `kept` or `removed`
- **THEN** the script SHALL exit with code `0`

#### Scenario: Run with at least one skipped override

- **WHEN** the script evaluates every override and at least one ends in `skipped`
- **THEN** the script SHALL exit with the dedicated "evaluation incomplete" code
  (distinct from `0` and from any pre-evaluation error code)

#### Scenario: Pre-evaluation failure

- **WHEN** the script cannot begin evaluation because `package.json` or
  `package-lock.json` is missing or malformed
- **THEN** the script SHALL exit with a non-zero code distinct from the
  "evaluation incomplete" code

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
