# Automated Changelog — Design Spec

**Date:** 2026-05-04
**Status:** Approved (pending user review of this written spec)
**Owner:** Geoff Franks

## Problem

The `Changes` file in this repository was frozen on 2024-08-29 with a notice directing readers to GitHub Releases. Since then, four releases (0.180.0, 0.181.0, 0.182.0, 0.183.0) have shipped to CPAN with a `Changes` file that does not describe them. The CPAN tarball — which is what end users see when they install the module — therefore contains a stale changelog.

The goal of this work is to resume automated maintenance of `Changes`, with three guarantees:

1. The `Changes` file content for a release matches the GitHub Release body for that release exactly.
2. `Changes` is updated *before* the release commit, so the CPAN tarball produced by `publish-cpan.yml` contains the new entry.
3. The maintainer can review and edit the release notes before they go out, in a normal PR review flow.

## Constraints and decisions

The following decisions were made during brainstorming and are load-bearing for the implementation:

- **Notes content is hybrid (auto + optional prose).** The auto-generated portion comes from GitHub's "generate release notes" API for the commit range `<last-tag>..HEAD`. Optional hand-written prose is added by editing the `Changes` file directly in the release PR.
- **Release flow is `workflow_dispatch` → release PR → merge → tag → GitHub release.** A maintainer triggers a "Prepare Release" workflow from the GitHub Actions UI; the workflow opens a PR; merging the PR triggers a "Finalize Release" workflow that tags and creates the GitHub release.
- **`Changes` is markdown, identical to the release body.** Each release section in `Changes` is a verbatim copy of the GitHub release body, prefixed only with a `## <version> — <YYYY-MM-DD>` header.
- **Version is selected by `bump=patch|minor|major`** (default `minor`), with an optional `version` string input as a fallback override.
- **Tags and version strings have no `v` prefix** (e.g. `0.184.0`), matching recent practice.
- **The four-release gap (0.180.0–0.183.0) is backfilled** from the existing GitHub release bodies, as a one-shot script.
- **`Changes` is the single source of truth for the release body.** The PR description is initialised from `Changes` for review convenience but is not read back. `finalize-release` extracts the topmost section of `Changes` and uses that as the GitHub release body.
- **The legacy `ci/release_notes.md` mechanism is dropped.** That convention was tied to the legacy Concourse pipeline; the new flow does not consult it. Hand-written prose is added by editing `Changes` in the release PR.
- **The legacy Concourse `ci/` directory is out of scope.** It is not in active use and will not be modified or deleted as part of this work.

## Architecture

Three new files in `.github/workflows/` and supporting helper scripts in `ci/scripts/`. The existing `publish-cpan.yml` is unchanged.

```
.github/workflows/
  prepare-release.yml      # NEW: workflow_dispatch  → opens release PR
  finalize-release.yml     # NEW: PR-merge trigger   → tags + creates GH release
  publish-cpan.yml         # UNCHANGED: fires on release-created
ci/scripts/
  prepare-release.sh       # NEW: file-mutation logic for prepare-release.yml
  build-release-notes.sh   # NEW: composes the markdown body via gh api
  extract-release-section.sh # NEW: pulls topmost section out of Changes for finalize-release
  backfill-changes.sh      # NEW: one-shot backfill of 0.180.0–0.183.0
```

Helper scripts are kept out of the workflow YAML so they can be shellchecked and locally dry-run with stub env vars.

### End-to-end flow

1. Maintainer opens GitHub Actions, picks **Prepare Release**, clicks **Run workflow**, selects `bump` (default `minor`) or types a `version` override, runs.
2. `prepare-release.yml`:
   1. Checks out `master`.
   2. Resolves the target version: if `version` input is given, use it as-is; else read the latest tag, parse semver, bump per `bump` input.
   3. Verifies no existing tag matches the target version. Fails loudly if one exists.
   4. Verifies no existing branch named `release/<version>` exists. Fails loudly if one exists.
   5. Verifies there is at least one commit on `master` since the previous tag. Fails if there is nothing to release.
   6. Calls `gh api repos/:owner/:repo/releases/generate-notes` with `tag_name=<new-version>`, `previous_tag_name=<last-tag>`, `target_commitish=master`. Captures the returned markdown body.
   7. Prepends a new section to `Changes`:
      ```
      ## <version> — <YYYY-MM-DD>

      <body markdown>

      ```
      The existing file contents (including the legacy "Starting on Aug 29, 2024..." notice) follow unchanged below.
   8. Updates `$VERSION` in `lib/Test/MockModule.pm` to the target version. (The `publish-cpan.yml` workflow already does this from the tag at publish time, but doing it here too means the source on `master` is correct between the merge and the tag-and-release step.)
   9. Commits the changes on a new branch `release/<version>` with message `release <version>`. Pushes the branch.
   10. Opens a PR to `master` titled `Release <version>`, with the same markdown body as the PR description and a label `release`.
3. Maintainer reviews the PR. If they want to edit the release notes, they edit `Changes` in the PR (not the description). They can also push additional commits to the release branch — `finalize-release` reads `Changes` at merge time.
4. Maintainer merges the PR (squash or merge commit, both work — the merge commit on `master` is what gets tagged).
5. `finalize-release.yml` triggers on `pull_request: closed` with `merged == true` and head ref matching `release/*`:
   1. Checks out `master` at the merge commit.
   2. Reads the topmost section of `Changes` (everything between the first `## ` line and the next `## ` line, exclusive of the next header).
   3. Parses the version from the section header.
   4. Creates an annotated tag `<version>` on the merge commit, pushes it.
   5. Creates a GitHub release via `gh release create <version> --title <version> --notes-file <extracted-body>`.
6. `publish-cpan.yml` fires on the release-created event, exactly as today, and uploads the tarball — which now contains the updated `Changes` — to CPAN.

### Source-of-truth rule

`Changes` is the canonical source for the release body. The PR description is a display-only view of it at PR-open time. `finalize-release` reads `Changes` at merge time to produce the GitHub release. This makes the three artefacts (tarball `Changes` section, git-tagged content, GitHub release page) match by construction with no two-way sync logic.

The PR template will state this rule at the top of every release PR description so reviewers do not edit the description and expect it to take effect.

### Backfill

`ci/scripts/backfill-changes.sh` is a one-shot script, run manually by the maintainer once before the first new release:

1. For each of `0.180.0`, `0.181.0`, `0.182.0`, `0.183.0` (oldest to newest):
   1. `gh release view <tag> --json body,publishedAt --jq '...'` to fetch the body and date.
   2. Format a section: `## <version> — <YYYY-MM-DD>` then a blank line then the body.
2. Insert the four sections, in chronological order (oldest at the bottom of the new block, newest at the top), at the top of `Changes`, immediately above the existing legacy `# NOTE: Starting on Aug 29, 2024...` notice.
3. Optionally remove or amend the "no longer updated" notice — recommendation: replace it with a single-line `# NOTE: Automated tracking resumed 2026-05-04 — see GitHub Releases for older entries pre-0.180.0.`
4. Commit on a branch `chore/backfill-changes` and open a PR for review.

The script is idempotent — re-running it after a successful run is a no-op (it detects the sections already exist by header match).

## Components

### `prepare-release.yml`

- **Trigger:** `workflow_dispatch`
- **Inputs:**
  - `bump` (choice: `patch`, `minor`, `major`; default `minor`)
  - `version` (string, optional override; if non-empty, takes precedence over `bump`)
- **Permissions:** `contents: write`, `pull-requests: write`
- **Steps:** checkout, run `ci/scripts/prepare-release.sh`, push branch, open PR via `gh pr create`.
- **Concurrency:** `group: release-prep` to prevent two simultaneous prepare-release runs.

### `finalize-release.yml`

- **Triggers:**
  - `pull_request` with `types: [closed]`, filtered to `if: github.event.pull_request.merged == true && startsWith(github.event.pull_request.head.ref, 'release/')`. Primary path.
  - `workflow_dispatch` with input `tag` (string). Retry path for the case where the PR-merge run created the tag but failed at `gh release create` (transient GH API error). When invoked manually, the workflow checks out the supplied tag and re-runs the release-create step only.
- **Permissions:** `contents: write`, `pull-requests: read`
- **Steps:** checkout merge commit (or supplied tag for retry), run `ci/scripts/extract-release-section.sh`, `git tag` and `git push` (skipped on retry path), `gh release create`.
- **Concurrency:** `group: release-finalize-${{ github.event.pull_request.number || inputs.tag }}` to prevent the merge-trigger and a manual retry from racing.

### `ci/scripts/prepare-release.sh`

- Inputs (env vars): `BUMP`, `VERSION_OVERRIDE`, `GH_TOKEN`, `REPO_ROOT`.
- Logic:
  1. Determine target version (override or computed bump).
  2. Validate (no existing tag, no existing branch, commits since last tag exist).
  3. Generate notes via `gh api`.
  4. Update `Changes` and `lib/Test/MockModule.pm`.
  5. Configure git user (bot identity), commit, push branch.
  6. Output the target version, branch name, and PR body file path on stdout for the workflow to consume.

### `ci/scripts/build-release-notes.sh`

- Thin wrapper around `gh api repos/:owner/:repo/releases/generate-notes`, isolated for testability.
- Inputs: `NEW_VERSION`, `PREV_TAG`, `TARGET_COMMITISH`.
- Output: markdown body on stdout.

### `ci/scripts/extract-release-section.sh`

- Reads `Changes`. Captures everything from the first `## ` heading line through (but not including) the next `## ` heading line.
- Outputs:
  - The version (parsed from the heading) on `version` line of stdout-as-key=value, or via `--version-only` flag.
  - The body markdown (heading stripped) to a file path supplied via `--out-file`.

### `ci/scripts/backfill-changes.sh`

- One-shot. Inputs: none beyond `GH_TOKEN`. Hard-codes the four versions to backfill since this is a one-time operation.
- Idempotent (skips if the section header already exists in `Changes`).

## Data flow

```
                           ┌────────────────────────────────────┐
maintainer clicks ──────► │ prepare-release.yml                 │
"Run workflow"            │  • compute version (bump or input)  │
                          │  • gh api generate-notes            │
                          │  • prepend Changes section          │
                          │  • bump $VERSION                    │
                          │  • commit on release/<v>            │
                          │  • gh pr create                     │
                          └────────────────────────────────────┘
                                          │
                                          ▼
                           ┌────────────────────────────────────┐
maintainer reviews        │ Release PR (release/<v> → master)   │
& optionally edits        │  • Changes is canonical             │
Changes file              │  • PR description is display-only   │
                          └────────────────────────────────────┘
                                          │ merge
                                          ▼
                           ┌────────────────────────────────────┐
                          │ finalize-release.yml                │
                          │  • extract topmost Changes section  │
                          │  • git tag <v> (annotated)          │
                          │  • git push tag                     │
                          │  • gh release create <v> --notes... │
                          └────────────────────────────────────┘
                                          │ release-created
                                          ▼
                           ┌────────────────────────────────────┐
                          │ publish-cpan.yml (UNCHANGED)        │
                          │  • patch $VERSION from ref_name     │
                          │  • Build dist                       │
                          │  • cpan-upload                      │
                          └────────────────────────────────────┘
```

## Error handling

| Condition | Handler | Behaviour |
|---|---|---|
| Tag `<version>` already exists | `prepare-release.sh` | Exit non-zero, print "Tag <version> already exists. Aborting." Workflow fails before push. |
| Branch `release/<version>` already exists | `prepare-release.sh` | Same as above. |
| No commits since last tag | `prepare-release.sh` | Exit non-zero, print "Nothing to release since <last-tag>." |
| `gh api generate-notes` returns empty body | `prepare-release.sh` | Continue but emit a warning; the maintainer can fill in the section in the PR. |
| Last tag cannot be parsed as semver | `prepare-release.sh` | Exit non-zero, instruct user to pass a `version` override. |
| `Changes` has no `## ` heading at finalize time | `extract-release-section.sh` | Exit non-zero, fail finalize-release loudly. The PR should not have been merged in this state. |
| Topmost section header version does not match the release branch name | `extract-release-section.sh` | Exit non-zero. Indicates someone edited the version inconsistently. |
| Maintainer pushes additional commits to `release/<v>` after PR open | (no special handling) | Fine — `finalize-release` reads `Changes` at merge time, so any edits are picked up automatically. |
| `gh release create` fails (e.g. transient network error) | `finalize-release.yml` | Workflow fails. The tag is already pushed. Re-running the workflow manually with `workflow_dispatch` (added as an additional trigger) creates the release using the same extracted body. |

`finalize-release.yml` therefore needs both the `pull_request: closed` trigger and a `workflow_dispatch` trigger (with a `tag` input) to handle the rare retry case.

## Testing

This is a CI-pipeline change. There is no unit test suite for GitHub Actions workflows in this repo. Verification is a mix of static checks and end-to-end exercise:

1. **Static checks** added to a new lint job (alongside [.github/workflows/lint.yml](.github/workflows/lint.yml)):
   - `actionlint` over `.github/workflows/*.yml`.
   - `shellcheck` over `ci/scripts/*.sh`.
2. **Local dry-run of helper scripts.** Each helper script accepts `DRY_RUN=1` env var; when set, it prints the actions it would take instead of executing git/gh mutating commands. Used during initial development.
3. **End-to-end on a fork or test branch.** Before merging this work to `master`:
   - Create a throwaway pre-release version (e.g. `0.184.0-rc1` if the project tolerates it, or use a fork). Trigger `prepare-release.yml`. Verify the PR is opened with the correct `Changes` diff and PR body.
   - Merge the PR (in the fork). Verify `finalize-release.yml` tags and creates the release. Verify the release body matches the `Changes` section.
   - Verify `publish-cpan.yml` produces a tarball whose `Changes` file contains the new section.

## Implementation preflight (decisions for the plan)

These cross-cutting decisions are recorded so the implementation plan can reference them without re-deciding:

1. **Test runner invocation.** Existing Perl tests: `./Build test`. New static checks: `actionlint ./.github/workflows/*.yml` and `shellcheck ./ci/scripts/*.sh`. No new Perl tests are added.
2. **Test seams.** Helper scripts read inputs from env vars and write outputs to stdout / files supplied via flags. They support a `DRY_RUN=1` mode for local exercise. Authentication is supplied via `GH_TOKEN` env var (workflow-provided in CI).
3. **Subagent model assignments.** Single-session implementation. No subagent dispatch.
4. **Build/lint gating.** Before any commit during implementation: `actionlint`, `shellcheck`, and `./Build test` must all pass. Lint job in CI enforces this on PRs.
5. **Scope boundaries.**
   - **In scope:** two new workflow files (`prepare-release.yml`, `finalize-release.yml`), four new helper scripts under `ci/scripts/`, an addition to `lint.yml` (or a new `lint-release-tooling.yml`), the one-shot backfill of 0.180.0–0.183.0, a `RELEASING.md` document explaining the maintainer flow, an update to the existing legacy notice in `Changes`.
   - **Out of scope:** modifications to `publish-cpan.yml`, modifications to `lib/`, modifications to the legacy Concourse `ci/pipeline.yml` or `ci/scripts/shipit`, branch protection rule changes, version-policy changes (semver discipline is a separate conversation).

## Open questions

None at design time. The following will be confirmed during implementation, but the answers are not load-bearing for the design:

- Bot identity for commits made by `prepare-release.yml`: default to `github-actions[bot] <41898282+github-actions[bot]@users.noreply.github.com>` unless the maintainer prefers a different identity.
- Whether to require at least one approval on the release PR (branch protection rule, out of scope here).
- Exact wording of the `RELEASING.md` document.
