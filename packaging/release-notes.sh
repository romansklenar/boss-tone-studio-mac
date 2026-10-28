#!/bin/sh
# Writes the GitHub Release body for a tagged version: its CHANGELOG.md section, then GitHub's generated notes.
# Release notes render every newline as a line break, so wrapped lines are joined.
#
#   packaging/release-notes.sh <x.y.z> <output file>
set -eu

VERSION=$1
OUT=$2
TAG="v$VERSION"
REPO=romansklenar/boss-tone-studio-mac

git rev-parse -q --verify "refs/tags/$TAG" > /dev/null || { echo "Error: tag $TAG does not exist" >&2; exit 1; }

# The section between `## [x.y.z] - date` and the next `## [` heading or the link references, wrapped lines joined:
# a non-blank line continues the previous one unless it starts a heading or a list item, or follows a heading.
NOTES=$(awk -v version="$VERSION" '
    index($0, "## [" version "]") == 1 { inside = 1; next }
    inside && (/^## \[/ || /^\[[^]]+\]: /) { exit }
    !inside { next }
    /^[ \t]*$/ { if (line != "") print line; line = ""; print ""; next }
    line != "" && line !~ /^#/ && ($0 ~ /^[ \t]/ || $0 !~ /^(#|[-*] |[0-9]+\. )/) {
        sub(/^[ \t]+/, ""); line = line " " $0; next
    }
    { if (line != "") print line; line = $0 }
    END { if (line != "") print line }
' CHANGELOG.md | awk 'NF { started = 1 } started')  # $(…) drops the trailing blank lines
[ -n "$NOTES" ] || { echo "Error: CHANGELOG.md has no section for $VERSION" >&2; exit 1; }

set -- -f "tag_name=$TAG"
if PREVIOUS=$(git describe --tags --abbrev=0 "$TAG^" 2> /dev/null); then
    set -- "$@" -f "previous_tag_name=$PREVIOUS"
fi
GENERATED=$(gh api "repos/$REPO/releases/generate-notes" "$@" --jq .body)

mkdir -p "$(dirname "$OUT")"
printf '%s\n\n%s\n' "$NOTES" "$GENERATED" | cat -s | sed 's/^## What'"'"'s Changed$/### What'"'"'s Changed/' > "$OUT"
echo "$OUT"
