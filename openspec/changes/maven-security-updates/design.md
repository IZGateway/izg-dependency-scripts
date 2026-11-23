# Design: maven-security-updates

## D1: Reusable workflows, not composite actions

Both pieces are whole jobs with their own runner, permissions and secrets, so they are reusable workflows (`workflow_call`).
- A composite action cannot read `secrets.*`. Both pieces need the App credentials and `GITHUB_TOKEN`.
- `maven-security-updates` has two jobs (open PR, then watch the PR build).
- `auto-merge-security-update` must run as its own job that `needs:` the caller's build job. A reusable-workflow job supports `needs:` and `if:` in the caller.

In a called workflow, `github.*` (repository, event, actor) and `GITHUB_TOKEN` belong to the caller, so `actions/checkout` and `gh` act on the caller's repository with no extra input.

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
