#!/usr/bin/env bash
# release.sh — semver bump, changelog, tag, push, GitHub Release, one command.
# Generic: copy into any project that keeps a VERSION file and a
# Keep-a-Changelog CHANGELOG.md with an [Unreleased] section.
#
# Flow: write your entry under [Unreleased], then run:
#   scripts/release.sh minor        # 0.2.0 -> 0.3.0
#   scripts/release.sh patch        # 0.2.0 -> 0.2.1
#   scripts/release.sh major        # 0.2.0 -> 1.0.0
#   scripts/release.sh --version 1.4.2   # exact version
#
# The script renames [Unreleased] to [X.Y.Z] - <date>, commits VERSION +
# CHANGELOG.md, tags vX.Y.Z, pushes commit + tag, and creates the GitHub
# Release with that section as notes (needs `gh` authenticated).
# Anything else changed in the tree is included in the release commit, so
# review `git status` first. Never put secrets in the notes.
set -euo pipefail

usage() {
  cat <<EOF
usage: $(basename "$0") <major|minor|patch> | --version X.Y.Z

Reads VERSION, bumps it, moves the [Unreleased] CHANGELOG section to the new
version, commits, tags vX.Y.Z, pushes, and creates the GitHub Release.
EOF
}

die() { printf 'error: %s\n' "$1" >&2; exit 1; }

command -v git >/dev/null 2>&1 || die "git is not installed"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_FILE="$ROOT/VERSION"
CHANGELOG="$ROOT/CHANGELOG.md"
[[ -f "$VERSION_FILE" ]] || die "VERSION not found at $VERSION_FILE"
[[ -f "$CHANGELOG" ]] || die "CHANGELOG.md not found at $CHANGELOG"

[[ $# -ge 1 ]] || { usage; exit 2; }
MODE="$1"
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

TODAY="$(date +%Y-%m-%d)"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
awk -v ver="$NEW" -v date="$TODAY" '
  /^## \[Unreleased\]/ { print "## [Unreleased]\n\n## [" ver "] - " date; next }
  { print }
' "$CHANGELOG" >"$TMP"

# Bail out if the Unreleased section was empty (only the header moved).
# NOTE: no /start/,/end/ range here: an end pattern like /^## \[/ also
# matches the start line itself, collapsing the range to one line.
section_body() {
  awk -v hdr="## [$1]" '
    substr($0, 1, length(hdr)) == hdr { on = 1; next }
    /^## / { on = 0 }
    on { print }
  ' "$2"
}
SEC="$(section_body "$NEW" "$TMP" | grep -v '^[[:space:]]*$' || true)"
[[ -n "$SEC" ]] || die "[Unreleased] is empty, write the notes first"

mv "$TMP" "$CHANGELOG"
printf '%s\n' "$NEW" >"$VERSION_FILE"
trap - EXIT

# Release notes = the new section body, plus compare link when possible.
NOTES="$(section_body "$NEW" "$CHANGELOG")"
PREV_TAG="$(git -C "$ROOT" describe --tags --abbrev=0 2>/dev/null || true)"
REPO="$(git -C "$ROOT" config --get remote.origin.url 2>/dev/null || true)"
SLUG=""
if [[ "$REPO" =~ github\.com[:/]([^/]+/[^/]+?)(\.git)?$ ]]; then
  SLUG="${BASH_REMATCH[1]}"
fi
if [[ -n "$PREV_TAG" && -n "$SLUG" ]]; then
  NOTES="$NOTES

**Full Changelog**: https://github.com/$SLUG/compare/$PREV_TAG...$TAG"
fi
NOTES_FILE="$(mktemp)"
trap 'rm -f "$NOTES_FILE"' EXIT
printf '%s\n' "$NOTES" >"$NOTES_FILE"

git -C "$ROOT" add VERSION CHANGELOG.md
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
