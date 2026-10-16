#!/usr/bin/env bash
# release.sh — semver bump, changelog, tag, push, GitHub Release, one command.
# Generic: copy into any project that keeps a VERSION file and a
# Keep-a-Changelog CHANGELOG.md with an [Unreleased] section.
#
# Flow A (curated): write your entry under [Unreleased], then run:
#   scripts/release.sh minor        # 0.2.0 -> 0.3.0
#   scripts/release.sh patch        # 0.2.0 -> 0.2.1
#   scripts/release.sh major        # 0.2.0 -> 1.0.0
#   scripts/release.sh --version 1.4.2   # exact version
#
# Flow B (automatic): skip the changelog, the notes come from commits:
#   scripts/release.sh minor --auto-notes
# Conventional subjects (feat:, fix:, breaking:) are grouped; anything else
# lands under Changed. Refuses when notes would leak key material, unless
# --force is passed after you reviewed them with --print-notes.
#
#   scripts/release.sh minor --auto-notes --print-notes  # preview, no changes
#
# The script renames [Unreleased] to [X.Y.Z] - <date>, commits VERSION +
# CHANGELOG.md, tags vX.Y.Z, pushes commit + tag, and creates the GitHub
# Release with that section as notes (needs `gh` authenticated).
# Anything else changed in the tree is included in the release commit, so
# review `git status` first. Never put secrets in the notes.
# If the repo has a package.json with a top-level "version", it is bumped in
# step and committed too (formatting preserved, first match only).
set -euo pipefail

usage() {
  cat <<EOF
usage: $(basename "$0") <major|minor|patch> [--auto-notes] [--force] [--print-notes]
   or: $(basename "$0") --version X.Y.Z [--auto-notes] [--force] [--print-notes]

Reads VERSION, bumps it, moves the [Unreleased] CHANGELOG section to the new
version, commits, tags vX.Y.Z, pushes, and creates the GitHub Release.
--auto-notes builds empty notes from commits since the previous tag.
--print-notes previews the notes and changes nothing.
EOF
}

die() { printf 'error: %s\n' "$1" >&2; exit 1; }

# Print the body of a ## [X] CHANGELOG section (header excluded).
# NOTE: no /start/,/end/ range: an end pattern like /^## \[/ also matches
# the start line itself, collapsing the range to one line.
section_body() {
  awk -v hdr="## [$1]" '
    substr($0, 1, length(hdr)) == hdr { on = 1; next }
    /^## / { on = 0 }
    on { print }
  ' "$2"
}

command -v git >/dev/null 2>&1 || die "git is not installed"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_FILE="$ROOT/VERSION"
CHANGELOG="$ROOT/CHANGELOG.md"
[[ -f "$VERSION_FILE" ]] || die "VERSION not found at $VERSION_FILE"
[[ -f "$CHANGELOG" ]] || die "CHANGELOG.md not found at $CHANGELOG"
BACKUP_DIR="$(mktemp -d)"
# Guarded cleanup: never pass an empty path to rm. (An empty "" arg to
# rm -rf misbehaves on some runtimes and can escape into the parent dir.)
cleanup() {
  [[ -n "${BACKUP_DIR:-}" ]] && rm -rf "$BACKUP_DIR"
  [[ -n "${RENAMED_TMP:-}" ]] && rm -f "$RENAMED_TMP"
  [[ -n "${GEN_TMP:-}" ]] && rm -f "$GEN_TMP"
  [[ -n "${NOTES_FILE:-}" ]] && rm -f "$NOTES_FILE"
  return 0
}
trap cleanup EXIT
cp "$VERSION_FILE" "$CHANGELOG" "$BACKUP_DIR/"

[[ $# -ge 1 ]] || { usage; exit 2; }
MODE="$1"; shift
AUTO_NOTES=0; FORCE=0; PRINT_ONLY=0
for flag in "$@"; do
  case "$flag" in
    --auto-notes) AUTO_NOTES=1 ;;
    --force) FORCE=1 ;;
    --print-notes) PRINT_ONLY=1 ;;
    *) usage; exit 2 ;;
  esac
done
NEW=""
if [[ "$MODE" == "--version" ]]; then
  NEW="${2:-}"
  [[ "$NEW" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "--version wants X.Y.Z"
else
  CUR="$(tr -d ' \t\r\n' <"$VERSION_FILE")"
  [[ "$CUR" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "VERSION holds '$CUR', want X.Y.Z"
  MAJOR="${CUR%%.*}"
  REST="${CUR#*.}"
  MINOR="${REST%%.*}"
  PATCH="${REST#*.}"
  case "$MODE" in
    major) NEW="$((MAJOR + 1)).0.0" ;;
    minor) NEW="$MAJOR.$((MINOR + 1)).0" ;;
    patch) NEW="$MAJOR.$MINOR.$((PATCH + 1))" ;;
    *) usage; exit 2 ;;
  esac
fi

TAG="v$NEW"
git -C "$ROOT" rev-parse --verify --quiet "refs/tags/$TAG" >/dev/null \
  && die "tag $TAG already exists"
grep -q '^## \[Unreleased\]' "$CHANGELOG" || die "no [Unreleased] section in CHANGELOG.md"
PREV_TAG="$(git -C "$ROOT" describe --tags --abbrev=0 2>/dev/null || true)"

# Never release with unrelated uncommitted work: only VERSION and
# CHANGELOG.md may be dirty (the script manages those itself).
DIRTY="$(git -C "$ROOT" status --porcelain -- . ':!VERSION' ':!CHANGELOG.md' || true)"
[[ -z "$DIRTY" ]] || die "uncommitted changes outside VERSION/CHANGELOG.md. Commit or stash first:
$DIRTY"

# Keep package.json in step when it carries a version (Node projects).
# Formatting is preserved by string replacement; only the first match moves.
PKG_SYNCED=0
PKG_FILE="$ROOT/package.json"
sync_package_json() {
  command -v node >/dev/null 2>&1 || die "package.json has a version but node is missing to sync it"
  node -e '
    const fs = require("fs");
    const p = process.argv[1], ver = process.argv[2];
    const s = fs.readFileSync(p, "utf8");
    const re = /("version"\s*:\s*")[^"]*(")/;
    if (!re.test(s)) { console.error("no top-level version field"); process.exit(1); }
    fs.writeFileSync(p, s.replace(re, "$1" + ver + "$2"));
  ' "$PKG_FILE" "$NEW" || die "package.json version sync failed"
  PKG_SYNCED=1
}

# --auto-notes: fill an empty [Unreleased] from commits since the previous
# tag. Grouped by conventional prefixes, everything else under Changed.
if [[ "$AUTO_NOTES" == "1" ]]; then
  if [[ -z "$(section_body Unreleased "$CHANGELOG" | grep -v '^[[:space:]]*$' || true)" ]]; then
    [[ -n "$PREV_TAG" ]] || die "--auto-notes needs a previous tag to diff against"
    GEN_ADDED=""; GEN_FIXED=""; GEN_CHANGED=""
    while IFS= read -r subject; do
      [[ -n "$subject" ]] || continue
      lower="$(printf '%s' "$subject" | tr '[:upper:]' '[:lower:]')"
      clean="$(printf '%s' "$subject" | sed -E 's/^(feat|add|fix|breaking|change|docs|chore|refactor|test|perf|ci|build)(\(.+\))?(!)?:[[:space:]]*//')"
      case "$lower" in
        feat*|add*) GEN_ADDED="$GEN_ADDED- $clean
" ;;
        fix*) GEN_FIXED="$GEN_FIXED- $clean
" ;;
        *) GEN_CHANGED="$GEN_CHANGED- $clean
" ;;
      esac
    done < <(git -C "$ROOT" log --format='%s' "${PREV_TAG}..HEAD" -- . ':!VERSION' ':!CHANGELOG.md' ':!package.json' || true)
    GEN=""; [[ -n "$GEN_ADDED" ]] && GEN="$GEN
### Added

$GEN_ADDED"
    [[ -n "$GEN_FIXED" ]] && GEN="$GEN
### Fixed

$GEN_FIXED"
    [[ -n "$GEN_CHANGED" ]] && GEN="$GEN
### Changed

$GEN_CHANGED"
    [[ -n "$GEN" ]] || die "no commits since $PREV_TAG, nothing to note"
    GEN_TMP="$(mktemp)"
    awk -v gen="$GEN" '/^## \[Unreleased\]/ { print; print gen; next } { print }' "$CHANGELOG" >"$GEN_TMP"
    mv "$GEN_TMP" "$CHANGELOG"
  fi
fi

TODAY="$(date +%Y-%m-%d)"
RENAMED_TMP="$(mktemp)"
awk -v ver="$NEW" -v date="$TODAY" '
  /^## \[Unreleased\]/ { print "## [Unreleased]\n\n## [" ver "] - " date; next }
  { print }
' "$CHANGELOG" >"$RENAMED_TMP"

# Bail out if the Unreleased section was empty (only the header moved).
SEC="$(section_body "$NEW" "$RENAMED_TMP" | grep -v '^[[:space:]]*$' || true)"
[[ -n "$SEC" ]] || die "[Unreleased] is empty, write the notes first (or re-run with --auto-notes)"

mv "$RENAMED_TMP" "$CHANGELOG"
printf '%s\n' "$NEW" >"$VERSION_FILE"

# Release notes = the new section body, plus compare link when possible.
NOTES="$(section_body "$NEW" "$CHANGELOG")"
REPO="$(git -C "$ROOT" config --get remote.origin.url 2>/dev/null || true)"
SLUG=""
if [[ "$REPO" =~ github\.com[:/]([^/]+/[^/]+)(\.git)?$ ]]; then
  SLUG="${BASH_REMATCH[1]%.git}"
fi
if [[ -n "$PREV_TAG" && -n "$SLUG" ]]; then
  NOTES="$NOTES

**Full Changelog**: https://github.com/$SLUG/compare/$PREV_TAG...$TAG"
fi
# Key material must never reach the release notes. Auto-generated notes come
# from commit subjects; a subject can smuggle a pasted secret.
if [[ "$FORCE" != "1" ]] && printf '%s' "$NOTES" | grep -qiE 'private key|BEGIN [A-Z ]*PRIVATE|ghp_|gho_|github_pat_|sk-(live|beta|test)|xox[bap]-'; then
  die "notes look like they contain a secret. Review, clean the commits, or re-run with --force"
fi

if [[ "$PRINT_ONLY" == "1" ]]; then
  printf 'would release %s with notes:\n---\n%s\n---\n' "$TAG" "$NOTES"
  cp "$BACKUP_DIR/VERSION" "$BACKUP_DIR/CHANGELOG.md" "$ROOT/"
  printf 'working tree restored, no changes made (--print-notes)\n'
  exit 0
fi
NOTES_FILE="$(mktemp)"
printf '%s\n' "$NOTES" >"$NOTES_FILE"

if [[ -f "$PKG_FILE" ]] && node -e 'const v=(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).version||"");process.exit(v?0:1)' "$PKG_FILE" 2>/dev/null; then
  sync_package_json
fi

git -C "$ROOT" add VERSION CHANGELOG.md
[[ "$PKG_SYNCED" == "1" ]] && git -C "$ROOT" add package.json
git -C "$ROOT" commit -m "Release $TAG" >/dev/null
git -C "$ROOT" tag -a "$TAG" -m "Release $TAG"
BRANCH="$(git -C "$ROOT" branch --show-current)"
git -C "$ROOT" push origin "$BRANCH" "$TAG"

if command -v gh >/dev/null 2>&1; then
  if [[ -n "$SLUG" ]]; then
    gh release create "$TAG" --title "$TAG" --notes-file "$NOTES_FILE" --repo "$SLUG"
  else
    ( cd "$ROOT" && gh release create "$TAG" --title "$TAG" --notes-file "$NOTES_FILE" )
  fi
  printf 'released %s\n' "$TAG"
else
  printf 'tag %s pushed. Install gh to create the Release, or do it by hand with:\n' "$TAG"
  printf '  gh release create %s --title %s --notes-file <file>\n' "$TAG" "$TAG"
fi
