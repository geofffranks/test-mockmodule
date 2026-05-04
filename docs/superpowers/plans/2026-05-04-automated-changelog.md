# Automated Changelog Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Resume automated maintenance of the `Changes` file so that the file in the CPAN tarball, the git-tagged content, and the GitHub Release body all match by construction. Releases are initiated by a `workflow_dispatch` button that opens a release PR; merging the PR tags and creates the GitHub release; the existing `publish-cpan.yml` ships the tarball.

**Architecture:** Two new GitHub Actions workflows (`prepare-release.yml`, `finalize-release.yml`) plus four helper shell scripts in `ci/scripts/`. `Changes` is the single source of truth for release-note content; finalize-release extracts the topmost section of `Changes` for the GitHub release body. A one-shot backfill script restores entries for 0.180.0–0.183.0.

**Tech Stack:** GitHub Actions (YAML), Bash, `gh` CLI, `jq`, `actionlint`, `shellcheck`.

**Spec:** [docs/superpowers/specs/2026-05-04-automated-changelog-design.md](../specs/2026-05-04-automated-changelog-design.md)

---

## File Structure

**Created:**

| Path | Responsibility |
|---|---|
| `ci/scripts/lib/semver.sh` | Pure-bash semver parse and bump. Sourced by other scripts. |
| `ci/scripts/extract-release-section.sh` | Extract topmost `## ` section from `Changes`, emit version + body to file. |
| `ci/scripts/build-release-notes.sh` | Wrap `gh api repos/{owner}/{repo}/releases/generate-notes`. Output markdown body. |
| `ci/scripts/prepare-release.sh` | Orchestrate: validate, build notes, prepend `Changes` section, bump `$VERSION`, commit on `release/<v>` branch. |
| `ci/scripts/backfill-changes.sh` | One-shot, idempotent backfill of 0.180.0–0.183.0 from existing GitHub releases. |
| `ci/scripts/tests/run.sh` | Minimal test harness: discovers and runs `test_*.sh` files. |
| `ci/scripts/tests/test_semver.sh` | TDD tests for `semver.sh`. |
| `ci/scripts/tests/test_extract_release_section.sh` | TDD tests for `extract-release-section.sh`. |
| `ci/scripts/tests/fixtures/Changes.fixture.md` | Fixture for `test_extract_release_section.sh`. |
| `.github/workflows/prepare-release.yml` | `workflow_dispatch` → release PR. |
| `.github/workflows/finalize-release.yml` | PR merge → tag + GitHub release. |
| `.github/workflows/lint-release-tooling.yml` | `actionlint` and `shellcheck` over the new files. |
| `RELEASING.md` | Maintainer-facing documentation of the release flow. |

**Modified:**

| Path | Why |
|---|---|
| `Changes` | Backfill 0.180.0–0.183.0 sections; replace the "no longer updated" notice. |
| `MANIFEST.SKIP` | Add `^RELEASING\.md` so the doc stays out of the CPAN tarball. |

`MANIFEST.SKIP` already excludes `^ci\b` and `\.github` so the new scripts and workflows are auto-excluded from CPAN distributions.

---

## Cross-cutting decisions

- **Bot identity for commits made by `prepare-release.yml`:** `github-actions[bot] <41898282+github-actions[bot]@users.noreply.github.com>`.
- **Tag/version format:** no `v` prefix (e.g. `0.184.0`). Matches recent practice.
- **Test runner for new shell code:** `bash ci/scripts/tests/run.sh`. No `bats` dependency — keeps the toolchain minimal.
- **Lint gating:** `actionlint`, `shellcheck`, and `bash ci/scripts/tests/run.sh` must all pass before any commit during implementation.
- **Out of scope:** anything in `lib/`, the legacy Concourse `ci/pipeline.yml` or `ci/scripts/shipit`, modifications to `publish-cpan.yml`, branch protection rule changes.

---

## Task 1: Add lint job for the new release tooling

**Why first:** subsequent tasks add YAML and shell files. The lint job catches syntax errors immediately and gives every later task a green-light gate.

**Files:**
- Create: `.github/workflows/lint-release-tooling.yml`

- [ ] **Step 1: Write the workflow**

Create `.github/workflows/lint-release-tooling.yml`:

```yaml
name: lint-release-tooling

on:
  push:
    branches:
      - '*'
    tags-ignore:
      - '*'
  pull_request:

jobs:
  actionlint:
    name: actionlint
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - name: Run actionlint
        uses: raven-actions/actionlint@v2
        with:
          files: ".github/workflows/*.yml"

  shellcheck:
    name: shellcheck
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - name: Install shellcheck
        run: sudo apt-get update && sudo apt-get install -y shellcheck
      - name: Run shellcheck
        run: |
          if [ -d ci/scripts ]; then
            find ci/scripts -type f -name '*.sh' -print0 \
              | xargs -0 -r shellcheck --shell=bash --severity=warning
          fi

  shell-tests:
    name: shell tests
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - name: Run shell tests
        run: |
          if [ -x ci/scripts/tests/run.sh ]; then
            bash ci/scripts/tests/run.sh
          else
            echo "ci/scripts/tests/run.sh not present yet — skipping"
          fi
```

- [ ] **Step 2: Verify workflow YAML parses**

Run: `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/lint-release-tooling.yml'))" && echo OK`
Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/lint-release-tooling.yml
git commit -m "ci: add lint job for release tooling (actionlint, shellcheck, shell-tests)"
```

---

## Task 2: Build minimal shell test harness

**Why:** subsequent TDD tasks need a runner. Keep it tiny — no bats dependency. Each test file `test_*.sh` defines functions starting with `test_`; the harness runs them, captures pass/fail, exits non-zero on any failure.

**Files:**
- Create: `ci/scripts/tests/run.sh`

- [ ] **Step 1: Write the harness**

Create `ci/scripts/tests/run.sh`:

```bash
#!/usr/bin/env bash
# Minimal shell test harness.
# Discovers ci/scripts/tests/test_*.sh, sources each, and runs every function
# whose name starts with `test_`. A test passes if the function returns 0.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

pass=0
fail=0
failed_tests=()

for test_file in "$SCRIPT_DIR"/test_*.sh; do
    [ -f "$test_file" ] || continue
    # shellcheck disable=SC1090
    source "$test_file"

    while read -r test_fn; do
        [ -n "$test_fn" ] || continue
        printf "  %s ... " "$test_fn"
        if (set -e; "$test_fn"); then
            printf "ok\n"
            pass=$((pass + 1))
        else
            printf "FAIL\n"
            fail=$((fail + 1))
            failed_tests+=("$(basename "$test_file"):$test_fn")
        fi
        unset -f "$test_fn"
    done < <(declare -F | awk '{print $3}' | grep '^test_' || true)
done

echo
echo "Results: $pass passed, $fail failed"
if [ "$fail" -gt 0 ]; then
    echo
    echo "Failed:"
    for f in "${failed_tests[@]}"; do
        echo "  - $f"
    done
    exit 1
fi
```

Make it executable:

```bash
chmod +x ci/scripts/tests/run.sh
```

- [ ] **Step 2: Verify it runs cleanly with no tests yet**

Run: `bash ci/scripts/tests/run.sh`
Expected: `Results: 0 passed, 0 failed` (exit 0).

- [ ] **Step 3: Lint the harness**

Run: `shellcheck --shell=bash --severity=warning ci/scripts/tests/run.sh`
Expected: no output, exit 0.

- [ ] **Step 4: Commit**

```bash
git add ci/scripts/tests/run.sh
git commit -m "ci: add minimal shell test harness for release tooling"
```

---

## Task 3: TDD semver bump library

**Files:**
- Create: `ci/scripts/lib/semver.sh`
- Test: `ci/scripts/tests/test_semver.sh`

- [ ] **Step 1: Write the failing tests**

Create `ci/scripts/tests/test_semver.sh`:

```bash
#!/usr/bin/env bash
# Tests for ci/scripts/lib/semver.sh

# shellcheck source=../lib/semver.sh
source "$REPO_ROOT/ci/scripts/lib/semver.sh"

assert_eq() {
    local expected=$1 actual=$2 msg=${3:-}
    if [ "$expected" != "$actual" ]; then
        echo "    expected: '$expected'"
        echo "    actual:   '$actual'"
        [ -n "$msg" ] && echo "    msg:      $msg"
        return 1
    fi
}

test_semver_bump_patch() {
    assert_eq "0.183.1" "$(semver_bump 0.183.0 patch)"
}

test_semver_bump_minor() {
    assert_eq "0.184.0" "$(semver_bump 0.183.0 minor)"
    assert_eq "0.184.0" "$(semver_bump 0.183.5 minor)"
}

test_semver_bump_major() {
    assert_eq "1.0.0" "$(semver_bump 0.183.0 major)"
    assert_eq "1.0.0" "$(semver_bump 0.183.5 major)"
}

test_semver_bump_strips_v_prefix_input() {
    assert_eq "0.184.0" "$(semver_bump v0.183.0 minor)"
}

test_semver_bump_rejects_unknown_part() {
    if semver_bump 0.183.0 huge >/dev/null 2>&1; then
        return 1
    fi
}

test_semver_bump_rejects_non_semver() {
    if semver_bump "not-a-version" minor >/dev/null 2>&1; then
        return 1
    fi
}

test_semver_validate_accepts() {
    semver_validate 0.183.0
}

test_semver_validate_rejects_missing_part() {
    if semver_validate 0.183 >/dev/null 2>&1; then
        return 1
    fi
}

test_semver_validate_rejects_v_prefix() {
    if semver_validate v0.183.0 >/dev/null 2>&1; then
        return 1
    fi
}
```

- [ ] **Step 2: Run tests — verify they fail**

Run: `bash ci/scripts/tests/run.sh`
Expected: errors about `semver_bump: command not found` (or similar — the file `ci/scripts/lib/semver.sh` doesn't exist yet).

- [ ] **Step 3: Write the library**

Create `ci/scripts/lib/semver.sh`:

```bash
#!/usr/bin/env bash
# Semver helpers. Use: `source ci/scripts/lib/semver.sh` from another script.
# All functions return non-zero on invalid input and write a message to stderr.

# semver_validate <version>
# Validates that <version> is a strict X.Y.Z (no v prefix, no pre-release).
semver_validate() {
    local v=$1
    if [[ ! "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "semver_validate: not a valid X.Y.Z version: '$v'" >&2
        return 1
    fi
}

# semver_bump <version> <part>
# part = patch | minor | major
# Strips a leading 'v' from <version> for convenience but emits no v in output.
semver_bump() {
    local current=$1 part=$2
    current="${current#v}"
    if ! semver_validate "$current"; then
        return 1
    fi
    local maj min pat
    IFS=. read -r maj min pat <<< "$current"
    case "$part" in
        major) echo "$((maj + 1)).0.0" ;;
        minor) echo "${maj}.$((min + 1)).0" ;;
        patch) echo "${maj}.${min}.$((pat + 1))" ;;
        *)
            echo "semver_bump: unknown part '$part' (expected patch|minor|major)" >&2
            return 1
            ;;
    esac
}
```

- [ ] **Step 4: Run tests — verify they pass**

Run: `bash ci/scripts/tests/run.sh`
Expected: `Results: 9 passed, 0 failed`.

- [ ] **Step 5: Lint**

Run: `shellcheck --shell=bash --severity=warning ci/scripts/lib/semver.sh ci/scripts/tests/test_semver.sh`
Expected: no output, exit 0.

- [ ] **Step 6: Commit**

```bash
git add ci/scripts/lib/semver.sh ci/scripts/tests/test_semver.sh
git commit -m "ci: add semver bump library with TDD coverage"
```

---

## Task 4: TDD extract-release-section.sh

This script reads `Changes`, finds the topmost `## <version> — <date>` heading, and emits the version (parsed from the heading) plus the section body (everything between that heading and the next `## ` heading, exclusive).

**Files:**
- Create: `ci/scripts/extract-release-section.sh`
- Create: `ci/scripts/tests/fixtures/Changes.fixture.md`
- Create: `ci/scripts/tests/test_extract_release_section.sh`

- [ ] **Step 1: Create the fixture**

Create `ci/scripts/tests/fixtures/Changes.fixture.md`:

```markdown
## 0.184.0 — 2026-05-04

## What's Changed
* feat: shiny thing by @koan-bot in https://example.com/pr/100
* fix: small issue by @geofffranks in https://example.com/pr/101

**Full Changelog**: https://example.com/compare/0.183.0...0.184.0

## 0.183.0 — 2026-05-01

## What's Changed
* Followup to PR #77 by @geofffranks in https://example.com/pr/79

**Full Changelog**: https://example.com/compare/0.181.0...0.183.0

# NOTE: Older entries omitted in fixture for brevity.
```

- [ ] **Step 2: Write the failing tests**

Create `ci/scripts/tests/test_extract_release_section.sh`:

```bash
#!/usr/bin/env bash
# Tests for ci/scripts/extract-release-section.sh

EXTRACT="$REPO_ROOT/ci/scripts/extract-release-section.sh"
FIXTURE="$REPO_ROOT/ci/scripts/tests/fixtures/Changes.fixture.md"

assert_eq() {
    local expected=$1 actual=$2
    if [ "$expected" != "$actual" ]; then
        echo "    expected: '$expected'"
        echo "    actual:   '$actual'"
        return 1
    fi
}

test_extract_version_only() {
    local v
    v=$("$EXTRACT" --changes-file "$FIXTURE" --version-only)
    assert_eq "0.184.0" "$v"
}

test_extract_body_to_file() {
    local out
    out=$(mktemp)
    "$EXTRACT" --changes-file "$FIXTURE" --out-file "$out" >/dev/null
    # First non-empty line should be "## What's Changed"
    local first
    first=$(grep -m1 -v '^[[:space:]]*$' "$out")
    rm -f "$out"
    assert_eq "## What's Changed" "$first"
}

test_extract_body_stops_at_next_section() {
    local out
    out=$(mktemp)
    "$EXTRACT" --changes-file "$FIXTURE" --out-file "$out" >/dev/null
    # Body must NOT contain the 0.183.0 heading
    if grep -q '^## 0\.183\.0' "$out"; then
        rm -f "$out"
        return 1
    fi
    # Body MUST contain the Full Changelog link of 0.184.0
    if ! grep -q '0.183.0...0.184.0' "$out"; then
        rm -f "$out"
        return 1
    fi
    rm -f "$out"
}

test_extract_fails_when_no_section() {
    local empty
    empty=$(mktemp)
    echo "no headings here" > "$empty"
    if "$EXTRACT" --changes-file "$empty" --version-only >/dev/null 2>&1; then
        rm -f "$empty"
        return 1
    fi
    rm -f "$empty"
}

test_extract_fails_when_heading_not_semver() {
    local bad
    bad=$(mktemp)
    cat > "$bad" <<'EOF'
## not-a-version — 2026-05-04

body
EOF
    if "$EXTRACT" --changes-file "$bad" --version-only >/dev/null 2>&1; then
        rm -f "$bad"
        return 1
    fi
    rm -f "$bad"
}
```

- [ ] **Step 3: Run tests — verify they fail**

Run: `bash ci/scripts/tests/run.sh`
Expected: failures (the script doesn't exist yet).

- [ ] **Step 4: Write the script**

Create `ci/scripts/extract-release-section.sh`:

```bash
#!/usr/bin/env bash
# Extract the topmost '## ' section from a Changes file.
#
# Usage:
#   extract-release-section.sh --changes-file <path> --version-only
#   extract-release-section.sh --changes-file <path> --out-file <path>
#
# In --version-only mode, prints the version (parsed from the first '## ' line)
# to stdout. The version must match X.Y.Z.
#
# In --out-file mode, writes the section body (everything after the first
# '## ' heading, up to but not including the next '## ' heading) to the
# file at --out-file, and prints the parsed version to stdout.
#
# Exit non-zero if there is no '## ' heading or the heading is not semver.

set -euo pipefail

CHANGES_FILE=""
OUT_FILE=""
VERSION_ONLY=0

while [ $# -gt 0 ]; do
    case "$1" in
        --changes-file) CHANGES_FILE=$2; shift 2 ;;
        --out-file)     OUT_FILE=$2;     shift 2 ;;
        --version-only) VERSION_ONLY=1;  shift ;;
        *) echo "extract-release-section: unknown arg '$1'" >&2; exit 2 ;;
    esac
done

if [ -z "$CHANGES_FILE" ]; then
    echo "extract-release-section: --changes-file is required" >&2
    exit 2
fi
if [ ! -f "$CHANGES_FILE" ]; then
    echo "extract-release-section: $CHANGES_FILE does not exist" >&2
    exit 2
fi
if [ "$VERSION_ONLY" -eq 0 ] && [ -z "$OUT_FILE" ]; then
    echo "extract-release-section: either --version-only or --out-file is required" >&2
    exit 2
fi

# Parse first '## ' heading line.
heading_line=$(grep -m1 '^## ' "$CHANGES_FILE" || true)
if [ -z "$heading_line" ]; then
    echo "extract-release-section: no '## ' heading found in $CHANGES_FILE" >&2
    exit 1
fi

# Extract version: '## X.Y.Z — date' or '## X.Y.Z - date' or '## X.Y.Z'
version=$(echo "$heading_line" | sed -E 's/^## ([0-9]+\.[0-9]+\.[0-9]+).*/\1/')
if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "extract-release-section: heading does not start with X.Y.Z: '$heading_line'" >&2
    exit 1
fi

echo "$version"

if [ "$VERSION_ONLY" -eq 1 ]; then
    exit 0
fi

# Extract body using awk: skip until first '## ', print until next '## '.
awk '
    BEGIN { found = 0 }
    /^## / {
        if (!found) { found = 1; next }
        else exit
    }
    found { print }
' "$CHANGES_FILE" > "$OUT_FILE"
```

Make executable:

```bash
chmod +x ci/scripts/extract-release-section.sh
```

- [ ] **Step 5: Run tests — verify they pass**

Run: `bash ci/scripts/tests/run.sh`
Expected: previous 9 + 5 new = `Results: 14 passed, 0 failed`.

- [ ] **Step 6: Lint**

Run: `shellcheck --shell=bash --severity=warning ci/scripts/extract-release-section.sh ci/scripts/tests/test_extract_release_section.sh`
Expected: no output, exit 0.

- [ ] **Step 7: Commit**

```bash
git add ci/scripts/extract-release-section.sh ci/scripts/tests/test_extract_release_section.sh ci/scripts/tests/fixtures/Changes.fixture.md
git commit -m "ci: extract-release-section helper with TDD coverage"
```

---

## Task 5: Build build-release-notes.sh

A thin wrapper around `gh api repos/{owner}/{repo}/releases/generate-notes`. No TDD — it's a one-call wrapper. Validation happens at integration time (Task 6 dry-run).

**Files:**
- Create: `ci/scripts/build-release-notes.sh`

- [ ] **Step 1: Write the script**

Create `ci/scripts/build-release-notes.sh`:

```bash
#!/usr/bin/env bash
# Generate auto release notes via GitHub's API.
#
# Required env: GH_TOKEN (gh CLI auth), GITHUB_REPOSITORY (owner/repo).
# Args:
#   --new-version <X.Y.Z>     Tag name to be created.
#   --previous-tag <X.Y.Z>    Last released tag, used as comparison base.
#   --target-commitish <ref>  Branch or commit (default: master).
#
# Output:
#   Writes the markdown body to stdout. Exits 0 on success, non-zero on error.

set -euo pipefail

NEW_VERSION=""
PREVIOUS_TAG=""
TARGET_COMMITISH="master"

while [ $# -gt 0 ]; do
    case "$1" in
        --new-version)      NEW_VERSION=$2;      shift 2 ;;
        --previous-tag)     PREVIOUS_TAG=$2;     shift 2 ;;
        --target-commitish) TARGET_COMMITISH=$2; shift 2 ;;
        *) echo "build-release-notes: unknown arg '$1'" >&2; exit 2 ;;
    esac
done

: "${NEW_VERSION:?--new-version is required}"
: "${PREVIOUS_TAG:?--previous-tag is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY env var must be set (e.g. owner/repo)}"

gh api \
    --method POST \
    -H "Accept: application/vnd.github+json" \
    "/repos/${GITHUB_REPOSITORY}/releases/generate-notes" \
    -f "tag_name=${NEW_VERSION}" \
    -f "previous_tag_name=${PREVIOUS_TAG}" \
    -f "target_commitish=${TARGET_COMMITISH}" \
    --jq '.body'
```

Make executable:

```bash
chmod +x ci/scripts/build-release-notes.sh
```

- [ ] **Step 2: Lint**

Run: `shellcheck --shell=bash --severity=warning ci/scripts/build-release-notes.sh`
Expected: no output, exit 0.

- [ ] **Step 3: Smoke-test against the live repo**

Requires `gh auth status` to be logged in. This will not modify anything.

Run:
```bash
GITHUB_REPOSITORY=geofffranks/test-mockmodule \
    ci/scripts/build-release-notes.sh \
    --new-version 0.184.0 \
    --previous-tag 0.183.0 \
    --target-commitish master \
    | head -20
```
Expected: markdown content beginning with `## What's Changed` (or empty if there are truly no commits since 0.183.0 — that's fine for a smoke test).

- [ ] **Step 4: Commit**

```bash
git add ci/scripts/build-release-notes.sh
git commit -m "ci: build-release-notes wrapper for GitHub generate-notes API"
```

---

## Task 6: Build prepare-release.sh orchestrator

Orchestrates the prepare-release workflow's logic. Supports `DRY_RUN=1` for local exercise without git mutations.

**Files:**
- Create: `ci/scripts/prepare-release.sh`

- [ ] **Step 1: Write the script**

Create `ci/scripts/prepare-release.sh`:

```bash
#!/usr/bin/env bash
# Orchestrate "prepare release":
#   - resolve target version (BUMP or VERSION_OVERRIDE)
#   - validate (no existing tag, no existing release branch, commits exist)
#   - generate release notes via build-release-notes.sh
#   - prepend a section to Changes
#   - bump $VERSION in lib/Test/MockModule.pm
#   - commit on a new branch release/<version>
#
# Required env:
#   BUMP                 patch|minor|major (used if VERSION_OVERRIDE empty)
#   VERSION_OVERRIDE     optional explicit X.Y.Z; takes precedence over BUMP
#   GH_TOKEN             gh CLI auth
#   GITHUB_REPOSITORY    owner/repo
#   GITHUB_OUTPUT        path for workflow outputs (set by GitHub Actions; optional locally)
# Optional env:
#   DRY_RUN              if set to '1', describe actions without git/branch push
#   REPO_ROOT            defaults to current working directory
#   GIT_USER_NAME        defaults to 'github-actions[bot]'
#   GIT_USER_EMAIL       defaults to '41898282+github-actions[bot]@users.noreply.github.com'
#
# Outputs (when GITHUB_OUTPUT is set):
#   version=<X.Y.Z>
#   branch=release/<X.Y.Z>
#   pr_body_file=<absolute path>

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$PWD}"
DRY_RUN="${DRY_RUN:-0}"
GIT_USER_NAME="${GIT_USER_NAME:-github-actions[bot]}"
GIT_USER_EMAIL="${GIT_USER_EMAIL:-41898282+github-actions[bot]@users.noreply.github.com}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/semver.sh
source "$SCRIPT_DIR/lib/semver.sh"

cd "$REPO_ROOT"

: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY env var must be set}"

run() {
    if [ "$DRY_RUN" = "1" ]; then
        echo "DRY_RUN: $*"
    else
        "$@"
    fi
}

# 1. Resolve target version.
LAST_TAG=$(git tag --sort=-version:refname | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | head -1 || true)
if [ -z "$LAST_TAG" ]; then
    echo "prepare-release: no semver-style tag found in repo" >&2
    exit 1
fi

if [ -n "${VERSION_OVERRIDE:-}" ]; then
    semver_validate "$VERSION_OVERRIDE"
    NEW_VERSION="$VERSION_OVERRIDE"
else
    : "${BUMP:?BUMP env var is required when VERSION_OVERRIDE is unset}"
    NEW_VERSION=$(semver_bump "$LAST_TAG" "$BUMP")
fi

echo "prepare-release: last tag = $LAST_TAG"
echo "prepare-release: new version = $NEW_VERSION"

# 2. Validate.
if git rev-parse "refs/tags/$NEW_VERSION" >/dev/null 2>&1; then
    echo "prepare-release: tag $NEW_VERSION already exists" >&2
    exit 1
fi
if git show-ref --quiet "refs/heads/release/$NEW_VERSION"; then
    echo "prepare-release: branch release/$NEW_VERSION already exists locally" >&2
    exit 1
fi
if git ls-remote --exit-code --heads origin "release/$NEW_VERSION" >/dev/null 2>&1; then
    echo "prepare-release: branch release/$NEW_VERSION already exists on origin" >&2
    exit 1
fi

if [ -z "$(git log "${LAST_TAG}..HEAD" --oneline)" ]; then
    echo "prepare-release: no commits since $LAST_TAG, nothing to release" >&2
    exit 1
fi

# 3. Generate release notes.
PR_BODY_FILE="$(mktemp -t prepare-release.XXXXXX)"
"$SCRIPT_DIR/build-release-notes.sh" \
    --new-version "$NEW_VERSION" \
    --previous-tag "$LAST_TAG" \
    --target-commitish master \
    > "$PR_BODY_FILE"

if [ ! -s "$PR_BODY_FILE" ]; then
    echo "prepare-release: WARNING — generated release notes are empty. Maintainer should fill in the section in the PR." >&2
    echo "_(Auto-generated notes were empty — please fill in.)_" > "$PR_BODY_FILE"
fi

# 4. Prepend a new section to Changes.
TODAY=$(date -u +%Y-%m-%d)
NEW_SECTION="$(mktemp -t prepare-release-section.XXXXXX)"
{
    echo "## ${NEW_VERSION} — ${TODAY}"
    echo
    cat "$PR_BODY_FILE"
    echo
} > "$NEW_SECTION"

if [ ! -f Changes ]; then
    echo "prepare-release: Changes file is missing from repo root" >&2
    exit 1
fi

NEW_CHANGES="$(mktemp -t prepare-release-changes.XXXXXX)"
cat "$NEW_SECTION" Changes > "$NEW_CHANGES"
mv "$NEW_CHANGES" Changes
rm -f "$NEW_SECTION"

# 5. Bump $VERSION in lib/Test/MockModule.pm.
perl -i -pe "s/^\\\$VERSION = '.*';/\\\$VERSION = '${NEW_VERSION}';/" lib/Test/MockModule.pm

# 6. Commit on release branch.
run git config user.name  "$GIT_USER_NAME"
run git config user.email "$GIT_USER_EMAIL"
run git checkout -b "release/$NEW_VERSION"
run git add Changes lib/Test/MockModule.pm
run git commit -m "release ${NEW_VERSION}"
run git push --set-upstream origin "release/$NEW_VERSION"

# 7. Emit outputs for the workflow.
if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
        echo "version=$NEW_VERSION"
        echo "branch=release/$NEW_VERSION"
        echo "pr_body_file=$PR_BODY_FILE"
    } >> "$GITHUB_OUTPUT"
fi

echo "prepare-release: done. version=$NEW_VERSION branch=release/$NEW_VERSION pr_body_file=$PR_BODY_FILE"
```

Make executable:

```bash
chmod +x ci/scripts/prepare-release.sh
```

- [ ] **Step 2: Lint**

Run: `shellcheck --shell=bash --severity=warning ci/scripts/prepare-release.sh`
Expected: no output, exit 0.

- [ ] **Step 3: Run shell tests to confirm no regressions**

Run: `bash ci/scripts/tests/run.sh`
Expected: `Results: 14 passed, 0 failed`.

- [ ] **Step 4: DRY_RUN smoke test from a clean checkout**

This exercises validation, notes generation, and file mutation without pushing. We'll roll back any local changes after.

```bash
git stash --include-untracked || true
DRY_RUN=1 BUMP=minor GITHUB_REPOSITORY=geofffranks/test-mockmodule \
    ci/scripts/prepare-release.sh
```
Expected: log output ending with `prepare-release: done. version=0.184.0 branch=release/0.184.0 ...`. The `Changes` file at the top will have a new `## 0.184.0 — <today>` section. `lib/Test/MockModule.pm` will have the new version string. Branch creation, commit, and push are all skipped (visible as `DRY_RUN: git ...` lines).

Roll back:

```bash
git checkout -- Changes lib/Test/MockModule.pm
git stash pop || true
```

- [ ] **Step 5: Commit**

```bash
git add ci/scripts/prepare-release.sh
git commit -m "ci: prepare-release orchestrator (validates, notes, bumps, commits)"
```

---

## Task 7: prepare-release.yml workflow

Triggers `workflow_dispatch`, calls `prepare-release.sh`, opens the PR.

**Files:**
- Create: `.github/workflows/prepare-release.yml`

- [ ] **Step 1: Write the workflow**

Create `.github/workflows/prepare-release.yml`:

```yaml
name: prepare-release

on:
  workflow_dispatch:
    inputs:
      bump:
        description: "Semver part to bump (ignored if 'version' is set)"
        required: false
        default: minor
        type: choice
        options:
          - patch
          - minor
          - major
      version:
        description: "Explicit X.Y.Z version (overrides 'bump' if non-empty)"
        required: false
        default: ""
        type: string

concurrency:
  group: release-prep
  cancel-in-progress: false

jobs:
  prepare:
    name: Prepare release PR
    runs-on: ubuntu-latest
    permissions:
      contents: write
      pull-requests: write
    steps:
      - uses: actions/checkout@v6
        with:
          fetch-depth: 0  # need full tag history for the semver bump

      - name: Run prepare-release
        id: prepare
        env:
          BUMP: ${{ inputs.bump }}
          VERSION_OVERRIDE: ${{ inputs.version }}
          GITHUB_REPOSITORY: ${{ github.repository }}
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: bash ci/scripts/prepare-release.sh

      - name: Open release PR
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          PR_BODY_FILE: ${{ steps.prepare.outputs.pr_body_file }}
          PR_BRANCH: ${{ steps.prepare.outputs.branch }}
          PR_VERSION: ${{ steps.prepare.outputs.version }}
        run: |
          set -euo pipefail
          # Prepend a maintainer note to the PR description so reviewers know
          # the file Changes is the canonical source — not the PR description.
          BODY_WITH_NOTE=$(mktemp)
          cat > "$BODY_WITH_NOTE" <<'NOTE_EOF'
          > **Reviewer note:** the `Changes` file in this PR is the source of truth for the release notes. The GitHub release body and CPAN tarball will be generated from the topmost section of `Changes` at merge time. Edits to **this PR description** will NOT be reflected in either — edit `Changes` directly if you want to amend the notes.

          NOTE_EOF
          cat "$PR_BODY_FILE" >> "$BODY_WITH_NOTE"

          gh pr create \
              --base master \
              --head "$PR_BRANCH" \
              --title "Release ${PR_VERSION}" \
              --body-file "$BODY_WITH_NOTE" \
              --label release
```

- [ ] **Step 2: Validate workflow YAML**

Run: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/prepare-release.yml'))" && echo OK`
Expected: `OK`.

- [ ] **Step 3: Lint with actionlint**

Run: `actionlint .github/workflows/prepare-release.yml` (install via `go install github.com/rhysd/actionlint/cmd/actionlint@latest` if not present, or skip locally and let CI catch it).
Expected: no output, exit 0. If actionlint isn't installed locally, note that the lint workflow added in Task 1 will catch issues on push.

- [ ] **Step 4: Note about the `release` label**

The `--label release` flag requires that label to exist on the repo. Verify or create:

```bash
gh label list --repo geofffranks/test-mockmodule | grep -q '^release\b' \
    || gh label create release --repo geofffranks/test-mockmodule --description "Release PR" --color FBCA04
```

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/prepare-release.yml
git commit -m "ci: add prepare-release workflow (workflow_dispatch -> release PR)"
```

---

## Task 8: finalize-release.yml workflow

Triggers on PR merge of any `release/*` branch into `master`. Tags the merge commit and creates the GitHub release. Also supports `workflow_dispatch` retry by tag.

**Files:**
- Create: `.github/workflows/finalize-release.yml`

- [ ] **Step 1: Write the workflow**

Create `.github/workflows/finalize-release.yml`:

```yaml
name: finalize-release

on:
  pull_request:
    types: [closed]
    branches: [master]
  workflow_dispatch:
    inputs:
      tag:
        description: "Existing tag to (re)create the GitHub release for"
        required: true
        type: string

concurrency:
  group: release-finalize-${{ github.event.pull_request.number || inputs.tag }}
  cancel-in-progress: false

jobs:
  finalize:
    name: Finalize release
    if: |
      github.event_name == 'workflow_dispatch'
      || (github.event.pull_request.merged == true && startsWith(github.event.pull_request.head.ref, 'release/'))
    runs-on: ubuntu-latest
    permissions:
      contents: write
      pull-requests: read
    steps:
      - name: Checkout merge commit
        if: github.event_name == 'pull_request'
        uses: actions/checkout@v6
        with:
          ref: ${{ github.event.pull_request.merge_commit_sha }}
          fetch-depth: 0

      - name: Checkout tag (retry path)
        if: github.event_name == 'workflow_dispatch'
        uses: actions/checkout@v6
        with:
          ref: ${{ inputs.tag }}
          fetch-depth: 0

      - name: Extract release section from Changes
        id: extract
        run: |
          set -euo pipefail
          BODY_FILE=$(mktemp)
          VERSION=$(bash ci/scripts/extract-release-section.sh \
              --changes-file Changes \
              --out-file "$BODY_FILE")
          echo "version=$VERSION"          >> "$GITHUB_OUTPUT"
          echo "body_file=$BODY_FILE"      >> "$GITHUB_OUTPUT"

      - name: Verify version matches branch (PR path)
        if: github.event_name == 'pull_request'
        env:
          PR_BRANCH: ${{ github.event.pull_request.head.ref }}
          EXTRACTED_VERSION: ${{ steps.extract.outputs.version }}
        run: |
          set -euo pipefail
          BRANCH_VERSION="${PR_BRANCH#release/}"
          if [ "$BRANCH_VERSION" != "$EXTRACTED_VERSION" ]; then
            echo "finalize-release: branch version '$BRANCH_VERSION' does not match Changes section version '$EXTRACTED_VERSION'" >&2
            exit 1
          fi

      - name: Verify version matches input tag (retry path)
        if: github.event_name == 'workflow_dispatch'
        env:
          INPUT_TAG: ${{ inputs.tag }}
          EXTRACTED_VERSION: ${{ steps.extract.outputs.version }}
        run: |
          set -euo pipefail
          if [ "$INPUT_TAG" != "$EXTRACTED_VERSION" ]; then
            echo "finalize-release: input tag '$INPUT_TAG' does not match Changes section version '$EXTRACTED_VERSION'" >&2
            exit 1
          fi

      - name: Tag and push (PR path only)
        if: github.event_name == 'pull_request'
        env:
          VERSION: ${{ steps.extract.outputs.version }}
        run: |
          set -euo pipefail
          git config user.name  "github-actions[bot]"
          git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
          git tag -a "$VERSION" -m "release $VERSION"
          git push origin "refs/tags/$VERSION"

      - name: Create GitHub release
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          VERSION: ${{ steps.extract.outputs.version }}
          BODY_FILE: ${{ steps.extract.outputs.body_file }}
        run: |
          set -euo pipefail
          gh release create "$VERSION" \
              --title "$VERSION" \
              --notes-file "$BODY_FILE"
```

- [ ] **Step 2: Validate workflow YAML**

Run: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/finalize-release.yml'))" && echo OK`
Expected: `OK`.

- [ ] **Step 3: Run shell tests to confirm no regressions**

Run: `bash ci/scripts/tests/run.sh`
Expected: `Results: 14 passed, 0 failed`.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/finalize-release.yml
git commit -m "ci: add finalize-release workflow (tag + create GH release on PR merge)"
```

---

## Task 9: Build backfill-changes.sh

One-shot, idempotent script. Pulls 0.180.0–0.183.0 release bodies from GitHub and prepends them to `Changes`. Replaces the legacy "no longer updated" notice with a "resumed" note.

**Files:**
- Create: `ci/scripts/backfill-changes.sh`

- [ ] **Step 1: Write the script**

Create `ci/scripts/backfill-changes.sh`:

```bash
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
```

Make executable:

```bash
chmod +x ci/scripts/backfill-changes.sh
```

- [ ] **Step 2: Lint**

Run: `shellcheck --shell=bash --severity=warning ci/scripts/backfill-changes.sh`
Expected: no output, exit 0.

- [ ] **Step 3: Confirm tests still pass**

Run: `bash ci/scripts/tests/run.sh`
Expected: `Results: 14 passed, 0 failed`.

- [ ] **Step 4: Commit (script only — running it is a separate task)**

```bash
git add ci/scripts/backfill-changes.sh
git commit -m "ci: add one-shot backfill script for Changes (0.180.0-0.183.0)"
```

---

## Task 10: Add RELEASING.md and update MANIFEST.SKIP

**Files:**
- Create: `RELEASING.md`
- Modify: `MANIFEST.SKIP`

- [ ] **Step 1: Write RELEASING.md**

Create `RELEASING.md`:

````markdown
# Releasing

Releases are driven by GitHub Actions. The maintainer's only manual step is clicking "Run workflow" and reviewing the resulting PR.

## Step 1 — Trigger Prepare Release

1. Go to **Actions → prepare-release** in GitHub.
2. Click **Run workflow**.
3. Pick a `bump` (default `minor`) or type an explicit `version`. Click **Run workflow**.

The workflow:

- Computes the new version from the latest semver tag.
- Calls GitHub's "generate release notes" API for `<last-tag>..master`.
- Prepends a `## <version> — <YYYY-MM-DD>` section to `Changes` containing the generated markdown.
- Bumps `$VERSION` in `lib/Test/MockModule.pm`.
- Commits to a new `release/<version>` branch.
- Opens a PR titled `Release <version>` against `master`.

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
````

- [ ] **Step 2: Update MANIFEST.SKIP to exclude RELEASING.md from CPAN tarball**

Open `MANIFEST.SKIP` and find the section after the included template (the maintainer-added section). Add the line `^RELEASING\.md` near the existing `^Test-MockModule-*` block:

```
# Avoid archives of this distribution
^Test-MockModule-*
^t/tmp

# Avoid Travis-CI configuration file
\.travis.yml

# Avoid maintainer-only docs
^RELEASING\.md
```

Apply via `Edit`:

- old_string:
  ```
  # Avoid Travis-CI configuration file
  \.travis.yml
  ```
- new_string:
  ```
  # Avoid Travis-CI configuration file
  \.travis.yml

  # Avoid maintainer-only docs
  ^RELEASING\.md
  ```

- [ ] **Step 3: Verify RELEASING.md is excluded by MANIFEST.SKIP**

Run:
```bash
perl Build.PL >/dev/null && ./Build manifest >/dev/null 2>&1 && grep -q '^RELEASING\.md$' MANIFEST && echo "FAIL: RELEASING.md is in MANIFEST" || echo "OK: RELEASING.md is excluded"
```
Expected: `OK: RELEASING.md is excluded`.

Note: `./Build manifest` may also reformat MANIFEST. If it does, restore via `git checkout -- MANIFEST` before committing.

- [ ] **Step 4: Commit**

```bash
git checkout -- MANIFEST 2>/dev/null || true
git add RELEASING.md MANIFEST.SKIP
git commit -m "docs: add RELEASING.md (excluded from CPAN tarball via MANIFEST.SKIP)"
```

---

## Task 11: Run the backfill (manual maintainer execution)

**This task requires user confirmation before running.** It modifies `Changes` based on live GitHub release data and produces a PR for review. The implementer agent must NOT auto-run this — surface to the user and wait for explicit go-ahead.

**Files:**
- Modify: `Changes`

- [ ] **Step 1: Confirm with the user**

Stop and ask: "Ready to run the backfill against the live repo? It will fetch 0.180.0–0.183.0 release bodies, prepend them to `Changes`, and stage the result on a new `chore/backfill-changes` branch."

Wait for explicit approval before continuing.

- [ ] **Step 2: Create branch and run backfill**

```bash
git checkout master
git pull --ff-only
git checkout -b chore/backfill-changes
GITHUB_REPOSITORY=geofffranks/test-mockmodule \
    GH_TOKEN=$(gh auth token) \
    bash ci/scripts/backfill-changes.sh
```
Expected output ends with `backfill: done. Review the diff before committing.`

- [ ] **Step 3: Review the diff**

Run: `git diff Changes`
Expected: four new sections at the top of the file (0.183.0, 0.182.0, 0.181.0, 0.180.0 in that order — newest first), plus the legacy "no longer updated" notice replaced with the "resumed" notice.

Spot-check at least one of the inserted bodies against `gh release view 0.181.0` to confirm content matches.

- [ ] **Step 4: Commit and open PR**

```bash
git add Changes
git commit -m "chore: backfill Changes for releases 0.180.0-0.183.0

Restores entries for releases that shipped during the period when the
Changes file was marked 'no longer updated'. Bodies are pulled directly
from the corresponding GitHub releases via gh release view --json body."
git push --set-upstream origin chore/backfill-changes
gh pr create \
    --base master \
    --title "Backfill Changes for 0.180.0-0.183.0" \
    --body "Restores Changes entries for the four releases that shipped after the 2024-08-29 freeze. Generated by ci/scripts/backfill-changes.sh."
```

- [ ] **Step 5: Verify idempotency**

After merging, optionally re-run the backfill on master to confirm it's a no-op:

```bash
git checkout master
git pull --ff-only
GITHUB_REPOSITORY=geofffranks/test-mockmodule \
    GH_TOKEN=$(gh auth token) \
    bash ci/scripts/backfill-changes.sh
```
Expected: four `backfill: section for X.Y.Z already present, skipping` lines, no diff to `Changes`.

If a diff appears, that's a bug — investigate before re-merging.

---

## Self-Review

Run before declaring the plan complete.

### Spec coverage

| Spec section | Implementing task(s) |
|---|---|
| Decision: hybrid notes (auto + optional prose) | Tasks 5, 6 (auto path); Task 7 PR template note (prose path) |
| Decision: `workflow_dispatch` → release PR → merge → tag → release | Tasks 6, 7, 8 |
| Decision: `Changes` is markdown, identical to release body | Task 6 (prepend), Task 8 (extract back) |
| Decision: `bump=patch\|minor\|major` with optional `version` override | Task 3 (lib), Task 6 (consume), Task 7 (workflow input) |
| Decision: no `v` prefix | Task 3 (`semver_validate` rejects v prefix); Task 6 (resolved version has no v); Task 7 (no v in branch/tag) |
| Decision: backfill 0.180.0–0.183.0 | Tasks 9, 11 |
| Decision: `Changes` is single source of truth | Task 7 (PR description note); Task 8 (reads `Changes`, not PR) |
| Decision: `ci/release_notes.md` is dropped | Not referenced in any task ✓ |
| Decision: legacy `ci/` Concourse out of scope | Not modified in any task ✓ |
| Components: `prepare-release.yml` | Task 7 |
| Components: `finalize-release.yml` | Task 8 |
| Components: `prepare-release.sh` | Task 6 |
| Components: `build-release-notes.sh` | Task 5 |
| Components: `extract-release-section.sh` | Task 4 |
| Components: `backfill-changes.sh` | Task 9 |
| Error handling: tag collision | Task 6 step 1 (validation block) |
| Error handling: branch collision | Task 6 step 1 (validation block) |
| Error handling: no commits since last tag | Task 6 step 1 (validation block) |
| Error handling: empty notes | Task 6 step 1 (warning + placeholder body) |
| Error handling: unparseable last tag | Task 6 step 1 (calls `semver_validate` on bumped output) |
| Error handling: `Changes` has no `## ` heading at finalize | Task 4 (script exits non-zero); Task 8 (workflow inherits exit) |
| Error handling: heading version mismatch | Task 8 step 1 (verify steps) |
| Error handling: `gh release create` transient failure | Task 8 (workflow_dispatch retry path) |
| Testing: actionlint + shellcheck lint job | Task 1 |
| Testing: shell test harness | Task 2 |
| Testing: `DRY_RUN=1` for local exercise | Task 6 step 4 |
| Out of scope: `lib/`, legacy Concourse, `publish-cpan.yml` | None modified ✓ |

All spec sections covered.

### Placeholder scan

Searched for: `TBD`, `TODO`, `implement later`, `add appropriate`, `similar to Task`, "fill in details". No matches. Every code step contains the actual code; every command step contains the actual command.

### Type / signature consistency

- `semver_bump <version> <part>` — used consistently in Task 3 (definition), Task 6 (`semver_bump "$LAST_TAG" "$BUMP"`).
- `semver_validate <version>` — used consistently in Task 3, Task 6.
- `extract-release-section.sh --changes-file <path> [--out-file <path>] [--version-only]` — used consistently in Task 4 (definition + tests), Task 8 (workflow consumption).
- `build-release-notes.sh --new-version --previous-tag --target-commitish` — used consistently in Task 5, Task 6.
- `prepare-release.sh` env contract (`BUMP`, `VERSION_OVERRIDE`, `GITHUB_REPOSITORY`, `GITHUB_OUTPUT`, `DRY_RUN`) — matches Task 7 workflow inputs and the script body.
- Workflow output names (`version`, `branch`, `pr_body_file`) — defined in Task 6, consumed in Task 7.

### Branch coverage

- `semver.sh` — patch / minor / major branches covered. Invalid input branch covered. v-prefix branch covered.
- `extract-release-section.sh` — happy path, missing-heading branch, non-semver-heading branch all covered.

### Workflow execution-order check

```
Task 1 (lint job) → green-light gate
Task 2 (test harness) → required by Tasks 3, 4
Task 3 (semver lib) → required by Task 6
Task 4 (extract-release-section) → required by Task 8
Task 5 (build-release-notes) → required by Task 6
Task 6 (prepare-release.sh) → required by Task 7
Task 7 (prepare-release.yml) → standalone after Task 6
Task 8 (finalize-release.yml) → standalone after Task 4
Task 9 (backfill script) → standalone
Task 10 (RELEASING.md + MANIFEST.SKIP) → standalone
Task 11 (run backfill) → requires Task 9 to be merged
```

No circular dependencies. Tasks 7, 8, 9, 10 are independent of each other and could be parallelized after their dependencies land.

---

## Done criteria

- [ ] All 11 tasks complete and committed.
- [ ] `bash ci/scripts/tests/run.sh` reports `14 passed, 0 failed`.
- [ ] `actionlint .github/workflows/*.yml` exits 0.
- [ ] `shellcheck --shell=bash --severity=warning ci/scripts/**/*.sh` exits 0.
- [ ] `prepare-release.yml` has been triggered manually at least once on a non-master test branch (or fork) and produced an opened release PR with the correct `Changes` diff.
- [ ] After merging that test PR, `finalize-release.yml` produced a tag and a GitHub release whose body matches the topmost section of `Changes`.
- [ ] `Changes` includes 0.180.0–0.183.0 sections (post-Task 11).
