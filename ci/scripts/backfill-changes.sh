#!/usr/bin/env bash
# One-shot, idempotent backfill of Changes for releases 0.180.0–0.183.0.
#
# Required env: GH_TOKEN (gh CLI auth), GITHUB_REPOSITORY (owner/repo).
# Run from repo root. Modifies Changes in-place and stages the result.
# Re-running is safe: existing sections (matched by '## <version> — ' header)
# are skipped.

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$PWD}"
cd "$REPO_ROOT"

: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY env var must be set}"

# Order matters: oldest first. Each is prepended; final order is newest at top.
VERSIONS=(0.180.0 0.181.0 0.182.0 0.183.0)

if [ ! -f Changes ]; then
    echo "backfill: Changes file is missing" >&2
    exit 1
fi

for v in "${VERSIONS[@]}"; do
    if grep -qE "^## ${v//./\\.} — " Changes; then
        echo "backfill: section for $v already present, skipping"
        continue
    fi

    echo "backfill: fetching $v..."
    body=$(gh release view "$v" --repo "$GITHUB_REPOSITORY" --json body --jq '.body')
    date=$(gh release view "$v" --repo "$GITHUB_REPOSITORY" --json publishedAt --jq '.publishedAt' | cut -dT -f1)

    if [ -z "$body" ] || [ -z "$date" ]; then
        echo "backfill: could not fetch body or date for $v" >&2
        exit 1
    fi

    section=$(mktemp)
    {
        echo "## ${v} — ${date}"
        echo
        echo "$body"
        echo
    } > "$section"

    new=$(mktemp)
    cat "$section" Changes > "$new"
    mv "$new" Changes
    rm -f "$section"

    echo "backfill: prepended section for $v"
done

# Replace the legacy "no longer updated" notice if present.
if grep -q '^# NOTE: Starting on Aug 29, 2024' Changes; then
    perl -i -0pe '
        s/^# NOTE: Starting on Aug 29, 2024[^\n]*\n[^\n]*\n[^\n]*github\.com\/geofffranks\/test-mockmodule\/releases\n\n/# NOTE: Automated tracking resumed 2026-05-04. See https:\/\/github.com\/geofffranks\/test-mockmodule\/releases for any older entries pre-0.180.0.\n\n/m
    ' Changes
fi

echo "backfill: done. Review the diff before committing."
