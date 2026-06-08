# Design: Safe Override Removal in `test-overrides.js`

## Context

`test-overrides.js` is one of three CLI scripts published by `@izgateway/dependency-scripts`. It runs in consumer repos (e.g., `IZGateway/izg-configuration-console`) under a nightly `security-updates.yml` workflow, between a "Test override removal" step and a follow-up `npm install` + `npm audit fix` step. Its job is to delete entries from the consumer's `package.json` `overrides` block that are no longer pulling their weight.

The current implementation answers "is this override still needed?" by reading `package-lock.json` and asking whether every resolved version of the overridden package already satisfies `>= overrideVersion`. The bug is that the lockfile was produced **with the override active**, so for an exact pin every resolution shows up at exactly the override version — the check always trivially succeeds, and the override is removed. The follow-up `npm install` then resolves a lower version through a transitive dependent, and the workflow ships a PR that has silently weakened SCA posture.

Reproduction is real, not theoretical: `IZGateway/izg-configuration-console` PR #521 removed `"postcss": "8.5.15"`, npm reverted to a lower `postcss` through a transitive dependent, and SCA flagged a medium-severity CVE. `"ajv": "8.20.0"` in the same repo has the same shape and is at risk on the next nightly run.

Constraints:
- The script must continue to run inside GitHub Actions runners in arbitrary consumer repos, with no IZ-Gateway-specific assumptions about the consumer's package layout.
- It must continue to operate on plain npm `overrides` syntax — we cannot force consumers to adopt a richer schema.
- It must work against private GitHub Packages registries (the consumer's `.npmrc` carries the auth setup).
- `semver` is the only declared peer dep; runtime deps should not grow without a strong reason.

Stakeholders: every IZGateway repo that consumes `@izgateway/dependency-scripts`. Most prominently `izg-configuration-console`; broadly any repo running the nightly security workflow.

## Goals / Non-Goals

**Goals:**
- Decide "is this override still required?" by observing what npm would resolve **without** the override, not by inspecting the lockfile produced **with** it.
- Report a tri-state outcome per override (`kept` / `removed` / `skipped`). (Exit codes originally distinguished "no removals" from "evaluation incomplete"; superseded by IGDD-2967 — see D4 — to a two-state `0`/`1` contract.)
- Preserve the existing in-place mutation contract on `package.json` (no `npm install` invoked inside the consumer's working tree by this script).
- Avoid scope explosion: do not introduce a new override schema, do not change `bin` names, do not require consumer workflow changes.

**Non-Goals:**
- Auditing the *contents* of vulnerabilities (i.e., running `npm audit` and parsing CVE IDs). The script does not need to know *why* an override was added; it only needs to know whether removing it lowers a resolved version.
- Touching `fix-all-vulnerabilities.js`. That script has its own bug surface and is explicitly out of scope per the concern doc.
- Supporting nested override syntax (`"pkg": { ".": "x", "sub": "y" }`). The current script only handles flat string overrides and none of the IZGateway consumers use the nested form. If we encounter a non-string override value, we classify it as `skipped` and move on rather than guessing.
- Building a JSON/structured output mode. Console output is sufficient for the nightly workflow today.

## Decisions

### D1: Trial removal in a scratch tree using `npm install --package-lock-only`

For each candidate override, copy `package.json` + `package-lock.json` (and `.npmrc` if present) into a scratch directory under `os.tmpdir()`. Edit the scratch `package.json` to remove the candidate override, then run `npm install --package-lock-only --ignore-scripts --no-audit --no-fund` in the scratch dir. Read the regenerated scratch lockfile and check whether any resolved version of the overridden package drops below the override floor. If not, the override is `removed`; otherwise it is `kept`. If the install fails for any reason, it is `skipped`.

**Why `--package-lock-only`:** it regenerates the lockfile without installing into `node_modules`, which is dramatically faster (no compiles, no extracts, no postinstall scripts) and exactly captures the "what would npm resolve" question we are asking. We do not need a populated `node_modules` because we are not running tests — we are only inspecting the resolution graph.

**Why `--ignore-scripts`:** defense in depth. Even without `node_modules` writes, lifecycle scripts could execute against the scratch tree under some npm versions and configurations. We are running this in CI against arbitrary dependency graphs; disabling scripts is the safe default.

**Why `--no-audit --no-fund`:** they are noise in this context and `--no-audit` avoids extra network round-trips.

**Alternatives considered:**
- *Full `npm install`* — captures real behavior most faithfully but is 5–20× slower per trial and offers no additional fidelity for our decision (which is purely about resolution).
- *Resolve semver ranges from lockfile metadata directly* (option 2 from the concern doc) — appealing because it avoids network calls, but it requires re-implementing npm's resolution algorithm including peer-dep resolution and override propagation. We would be writing and maintaining a parallel resolver. Not worth it.
- *Static check of parents' published manifests via `npm view`* — same fragility as the above without even the lockfile to anchor against.

### D2: Each trial removes exactly one override; others stay in place

When evaluating override A, we keep every other override (B, C, …) in the scratch `package.json`. This intentionally produces a conservative classification: override A is `removed` only if it is redundant *given the other overrides*.

**Rationale:** It prevents the cascading-removal failure mode. If overrides A and B both contribute to keeping package P safe, an all-at-once trial would show P resolving below the floor and we would not know which removal caused it. Per-override trials give a clean signal: each override is evaluated against the same baseline that the consumer is actually running today.

**Alternative considered:**
- *All-at-once trial then per-override fallback*. Fastest happy path (1 install for everything-removed; falls back to N installs only when the all-at-once trial shows a regression). Tempting, but it doubles code paths and is unnecessary at IZGateway's override counts (typical consumer has <10 overrides; each `--package-lock-only` is ~5–15s; N × that is acceptable for a nightly job). We can adopt the optimization later if runtime becomes a real problem.

### D3: `package.json` is written exactly once, at the end of the run

Decisions accumulate in memory. After all overrides have been classified, the script writes `package.json` once with all `removed` overrides deleted (and the `overrides` key itself deleted if empty). Mid-run failure leaves the consumer's tree untouched.

**Why:** It matches the spec's atomic-mutation requirement, makes rollback trivial (don't write the file), and avoids confusing the follow-up `npm install` with a half-mutated state if the script is killed.

### D4: Exit codes

> **Superseded by IGDD-2967 (PR #8).** The tri-state exit code below (`2` for "evaluation incomplete") caused the nightly workflow to fail in Configuration Console and Transform UI, because `set -e`/`errorlevel` callers treated the `2` as fatal and a `skipped` override is a routine, non-fatal outcome. The contract is now two-state — see the revised table.

**Revised (IGDD-2967):**

| Code | Meaning |
| ---- | ------- |
| `0`  | Evaluation completed; every override classified as `kept`, `removed`, or `skipped`. |
| `1`  | Genuine failure: `package.json` / `package-lock.json` missing or malformed, scratch setup failure, or an uncaught exception. |

A `skipped` outcome is a normal result, not an error, and does not affect the exit code. Callers run the script without an error guard and detect changes via `git diff`, the same contract as `update-overrides` and `fix-vulnerabilities`.

**Original rationale (no longer in effect):** `2` was chosen over `1` for "evaluation incomplete" because Bash conventions reserve `1` for general/unspecified errors and the nightly workflow was expected to distinguish "I could not finish my job" from "I never got started." In practice no caller needed that distinction, and treating `skipped` as a distinct non-zero code only produced false failures.

**Alternative considered:**
- *Single non-zero code for any not-clean state*. Originally rejected as losing a distinction the spec required; IGDD-2967 adopts essentially this — `skipped` is folded into the normal `0` path and only genuine errors return non-zero.

### D5: Scratch-tree carries `.npmrc` if present

`npm install --package-lock-only` still talks to registries — it has to resolve versions and integrity hashes. IZGateway consumers authenticate to GitHub Packages via the consumer repo's `.npmrc` and `${NPM_TOKEN}` / `${GITHUB_TOKEN}`. If the scratch tree lacks `.npmrc`, npm will use the default registry and fail to resolve `@izgateway/*` private packages, classifying every override as `skipped`.

The script SHALL copy the consumer's `.npmrc` (if present in CWD) into the scratch directory before running `npm install`. Environment variables (`NPM_TOKEN`, `GITHUB_TOKEN`) are inherited naturally because we invoke `npm` as a child process. We do **not** copy parent-directory or user-home `.npmrc` files; relying on CWD's `.npmrc` matches the consumer's actual install behavior.

**Alternative considered:**
- *Run the trial in CWD instead of a scratch dir* (so `.npmrc`, env, and npm config all just work). Rejected — it would write `package-lock.json` (or worse, `node_modules`) into the consumer's tree, violating the "no working-tree pollution" requirement.

### D6: Reuse existing lockfile traversal; add a path-keyed traversal for per-path comparison

The existing `findAllResolvedVersions` helper that walks `package-lock.json` for resolved versions of a given package stays — it still answers the "is this package in the graph at all?" question and serves as a fallback for v1 lockfiles that lack the `packages` key.

A second helper, `findResolvedByPath`, returns a `{ path: version }` map for v3-style lockfiles (the universal modern format). This is the data the per-path comparison in [spec.md → "Removal decisions SHALL be based on natural resolution"](./specs/override-evaluation/spec.md) requires: for each path where the overridden package resolves in the trial lockfile, we look up the same path in the consumer's current lockfile and decide whether the trial represents a regression *at that path*.

The path-keyed comparison is what lets us avoid false `kept` outcomes when an unrelated nested override pins a sub-tree below the floor on purpose — the eslint-nested `ajv@6.x` next to a top-level `ajv@8.20.0` override is a real consumer shape, not an edge case.

The v1 fallback path keeps the old aggregate-version logic (no path keys available), accepting that v1 consumers will see the original failure mode if they have nested overrides — modern npm has not produced v1 lockfiles since npm 6, so this is acceptable.

### D7: Per-override outcome reporting

Print one line per override at the end of the run, in this format:

```
postcss@8.5.15        kept     (natural resolution would drop to 8.4.31)
ajv@8.20.0            kept     (natural resolution would drop to 8.17.1)
old-thing@1.2.3       removed  (natural resolution: 1.2.3)
flaky-thing@2.0.0     skipped  (trial install failed: npm ERR! 503 ...)
```

The verbose explanation in parentheses is opportunistic — included when we can attribute it cleanly, omitted when we cannot. The fixed-width outcome column makes the report grep-able from workflow logs.

## Risks / Trade-offs

- **[Risk]** Nightly runtime increases roughly linearly with override count. For the IZGateway repo with the most overrides (~10 entries), this could add ~1–3 minutes per run.
  → **Mitigation:** Acceptable in absolute terms for a nightly job. If a consumer accumulates an unusually large override block, we can revisit D2 with the all-at-once-then-fallback optimization.

- **[Risk]** A registry outage at trial time would classify every override as `skipped`, producing exit code `2` and no removals.
  → **Mitigation:** This is the correct failure mode — better to skip than to silently delete an override based on incomplete information. The workflow already runs nightly and is non-blocking; a 24-hour delay in trimming truly-redundant overrides is fine. Workflow callers should treat exit code `2` as visible (job summary annotation) but non-fatal.

- **[Risk]** `.npmrc` copied into scratch could contain secrets in `auth`/`_authToken` fields. The scratch tree lives under `os.tmpdir()` and is readable by the same user; on a CI runner this is the same trust boundary that already exists for the consumer's checkout.
  → **Mitigation:** Clean up the scratch directory before exiting (best-effort `rm -rf`), and rely on the fact that CI runners are ephemeral. Do **not** log the contents of `.npmrc`. This is no worse than the current security posture during a regular `npm install`.

- **[Risk]** `npm install --package-lock-only` behavior has varied historically across npm versions (notably around peer-dep resolution and `overrides` semantics).
  → **Mitigation:** The script already assumes `npm` is on PATH and the published package's audience is npm 8+ via Node 18+. Document the minimum npm version in the README if not already implied by the Node version. If a consumer is on a much older npm, the trial will simply fail and we will report `skipped` — fail-safe.

- **[Trade-off]** Conservative per-override evaluation means that pairs of overrides that *together* are no longer needed (because each one's other-paths now satisfy the floor) will both be classified `kept`. This is by design: avoiding a silent regression is worth occasionally keeping a stale override one more week, until a human notices.

- **[Trade-off]** Non-string override values (nested form) are classified `skipped` rather than attempting to evaluate them. This is consistent with "default to keep when we cannot determine" and matches today's de-facto behavior (the current script would also fail on those, just less explicitly).

## Migration Plan

1. Implement and merge the changes to `test-overrides.js` in this repo. CI publishes a `-dev` build on the PR; consumer repos can pin to `@dev` to dry-run.
2. Bump label `bump:minor` on the PR. On merge, `ci.yml` publishes `1.1.0` (assuming current `1.0.3`) and updates the floating `@v1` tag.
3. Consumer repos pinned to `@v1` pick up the fix automatically on their next workflow run.
4. For `IZGateway/izg-configuration-console` specifically: after the new version lands, manually re-add `"postcss": "8.5.15"` and `"ajv": "8.20.0"` to `overrides` if PR #521 has already merged. Then verify the next nightly run reports them as `kept`.

**Rollback:** Consumers can pin to `@v1.0.3` to revert to the previous behavior. The release pipeline does not delete published versions.

## Open Questions

- **Should the script log a structured JSON summary to a side file (e.g., `test-overrides-report.json`) for downstream tooling to consume?** Today, nothing parses the script's output; the nightly workflow only acts on the diff in `package.json`. Holding off until a real consumer asks for it.
- **Do we want a `--dry-run` flag** that runs the evaluation but never mutates `package.json`? Useful for human-driven audits. Likely yes, but small enough to add later without breaking anyone.
- **Should `skipped` outcomes be retryable in the same run** (e.g., one retry on transient registry errors)? Probably yes, but with a tight budget — one retry, no backoff longer than a few seconds. To decide during implementation.
