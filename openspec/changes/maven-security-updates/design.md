# Design: maven-security-updates

## D1: Composite actions for the logic, reusable workflows as recipes

The logic lives in five composite actions (`.github/actions/`), and the two reusable workflows (`workflow_call`) are short recipes that wire them together.

- **Actions are the reusable parts.** Three of them (`open-signed-pr`, `rerun-cancelled-build`, `auto-merge-bot-pr`) do not depend on Maven, so an npm workflow (IGDD-2969) or izgw-bom can use them without the Maven steps. `setup-izg-maven` can replace the hand-written `settings.xml` in every IZ Gateway Maven workflow.
- **Workflows keep the caller small.** A caller still needs only ~45 lines for Security Updates and ~15 lines in its CI. Calling the actions directly would make every caller define jobs, runners, permissions, checkout and setup itself, so callers use the workflows.
- **Whole-job concerns stay in the workflows:** runner, job permissions, `timeout-minutes`, job outputs, the second `watch-pr-build` job, and the auto-merge job-level `if:` (so other PRs show a skipped job rather than a failure). These cannot be expressed in a composite action.
- **Secrets are inputs to the actions.** `secrets.*` is empty inside a composite action, so the workflows pass `GITHUB_TOKEN`, the App token, or the App id and key.

In a called workflow and in a composite action, `github.*` (repository, event, actor) belongs to the caller, so `actions/checkout` and `gh` act on the caller's repository with no extra input.

## D1a: How the workflows reference the actions

The workflows use `IZGateway/izg-dependency-scripts/.github/actions/<name>@v1`, not `./.github/actions/<name>`. Inside a reusable workflow a local path is resolved against the caller's checked-out repository, which does not contain these actions. The `@v1` ref keeps workflows and actions on the same release. To test a branch of this repository end to end, the action refs in the workflows are pointed at the branch temporarily and reverted before merge. A breaking change to an action's inputs needs a `v2` release of both.

## D2: Version pin `@v1`

Callers use `@v1`, the floating major tag the release job in `ci.yml` moves on each release. The auto-merge workflow decides what can be merged into `develop`, so callers do not follow `@main`. Fixes reach consumers on release; a breaking input change needs `v2`.

## D3: Identity and tokens

| Operation | Token | Why |
|---|---|---|
| Create blobs, tree, commit, branch; open and close PRs; merge | `izg-dependency-bot` App token | Events raised with `GITHUB_TOKEN` start no workflows, so the PR's CI and the post-merge develop build would never run. The App avoids a personal token. |
| Read GitHub Packages, activity log, PR files and commits; re-run a cancelled build | `GITHUB_TOKEN` | Least privilege |
| Approve | `GITHUB_TOKEN` (`github-actions[bot]`) | Must differ from the PR author to count as a review |

## D4: Signed commit through the Git Data API

The commit is created with `POST /git/blobs`, `/git/trees`, `/git/commits` and `/git/refs`, passing no author or committer. GitHub then signs it: author `izg-dependency-bot[bot]`, committer `web-flow`, verification `valid`. A commit made with `git commit --author=...` and pushed cannot produce that combination. Every file `git diff --name-only` reports is added to the tree, so multi-module projects work.

Testing on 2026-11-18 showed the committer is always `web-flow`, never the bot (izgw-transform PR #296). The auto-merge check expects exactly `<bot-login> web-flow true`.

## D5: Auto-merge checks (fail closed)

1. Job `if:` limits the job to pull_request events into `base-branch`, from the same repository, opened by `bot-login`, on a `branch-prefix*` branch. Any other PR shows a skipped job.
2. Provenance: `GET /repos/{repo}/activity?ref=refs/heads/<branch>` lists every write with the authenticated actor. The set of actors must be exactly `bot-login`, there must be no `force_push`, and the last write's `after` must equal the PR head SHA that CI tested. Commit metadata can be faked; the activity log cannot.
3. Content: every changed path matches `allowed-files`, and every commit's author, committer and verification are `<bot-login> web-flow true`.

Each check exits non-zero with an `::error::` stating why, so a refused merge is visible in the run.

## D6: Nightly vs manual

The caller passes `auto-merge` (true for the schedule, or a manual run that opts in). The branch is `<prefix>/nightly-*` or `<prefix>/manual-*`, and only nightly branches qualify for auto-merge. Opening a new nightly PR closes older open nightly PRs; manual PRs are left alone.

## D7: Cancelled PR builds

A consumer CI workflow with a `concurrency:` group keeps one pending run per group; GitHub cancels the older pending run. The `watch-pr-build` job finds the PR's CI run by branch and head SHA, waits for it, and re-runs it if it was cancelled, up to `max-build-reruns`. It stops when the build completes with any other conclusion or the PR is no longer open.

## D8: What stays in the consumer

Repository-specific and kept per repository: `automation-exclusions.txt`, `versions-rules.xml` (izgw-bom's `rulesUri` points to the project root), the pom's patch-only `versions-maven-plugin` override and version properties, the schedule, and the Maven server ids.

## Testing

Before release, the izgw-transform caller points at `@IGDD-2766` (this branch) and runs the same pre-merge test used for the original workflow: a temporary push trigger opens a bot PR into the izgw-transform feature branch, its CI runs, and auto-merge approves and merges it. The temporary commit and the bot's merge are reverted, and the caller is switched to `@v1` after this change is released.
