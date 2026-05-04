# Releasing

Releases are driven by GitHub Actions. The maintainer's only manual step is clicking "Run workflow" and reviewing the resulting PR.

## Step 1 — Trigger Prepare Release

1. Go to **Actions → prepare-release** in GitHub.
2. Click **Run workflow**.
3. Pick a `bump` (default `minor`) or type an explicit `version`. Click **Run workflow**.

The workflow:

- Computes the new version from the latest semver tag.
- Calls GitHub's "generate release notes" API for `<last-tag>..main`.
- Prepends a `## <version> — <YYYY-MM-DD>` section to `Changes` containing the generated markdown.
- Bumps `$VERSION` in `lib/Test/MockModule.pm`.
- Commits to a new `release/<version>` branch.
- Opens a PR titled `Release <version>` against `main`.

## Step 2 — Review the release PR

The PR description is **display only**. The `Changes` file in the PR is the canonical source for the release notes — the GitHub release body and the file inside the CPAN tarball will both be generated from it at merge time.

To amend the notes (add prose, fix a wrong PR title, group entries by category), edit `Changes` directly in the PR. Push additional commits to the `release/<version>` branch as needed.

When you're happy, merge the PR.

## Step 3 — Finalize Release (automatic)

On merge, the `finalize-release` workflow:

- Extracts the topmost `## ` section from `Changes`.
- Verifies the section's version matches the branch name (`release/<version>`).
- Tags the merge commit `<version>` and pushes the tag.
- Creates a GitHub release titled `<version>` with the section body as the release notes.

## Step 4 — CPAN upload (automatic)

The existing `publish-cpan` workflow fires on the new release, builds the dist, and uploads the tarball to CPAN. The tarball's `Changes` file contains the new section because the release commit (which the tag points to) included it.

## Failure modes

| Symptom | Cause | Fix |
|---|---|---|
| `prepare-release` fails with "Tag X.Y.Z already exists" | The bump produced a version that's already tagged. | Pass an explicit `version` input that hasn't been used. |
| `prepare-release` fails with "Branch release/X.Y.Z already exists" | Stale branch from a previous attempt. | Delete the stale branch (`git push origin --delete release/X.Y.Z`) and re-run. |
| `prepare-release` fails with "no commits since X.Y.Z" | Nothing new to release. | Don't release. |
| `finalize-release` tags but fails at `gh release create` (transient) | GitHub API hiccup. | Re-run `finalize-release` manually via `workflow_dispatch` with `tag=X.Y.Z`. The tag-and-push step is skipped on the retry path. |
| Version in `Changes` heading doesn't match branch name | Maintainer edited the heading line in the PR but not the branch. | Either rename the branch or fix the heading; finalize-release fails loudly to catch this. |
