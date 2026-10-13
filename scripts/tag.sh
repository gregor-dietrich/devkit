#!/bin/bash

set -euo pipefail

echo "Starting tagging operation..."

cd "$PROJECT_ROOT"

# shellcheck source=SCRIPTDIR/lib/release_tag.sh
. "$DEVKIT/scripts/lib/release_tag.sh"

# Fetching origin brings the tags on its branches for the suggestion.
git fetch origin

# Release from the default branch's tip, as the remote reports it now.
REMOTE_HEAD=$(git ls-remote --symref origin HEAD)
REMOTE_TIP=$(awk '$2 == "HEAD" {print $1}' <<<"$REMOTE_HEAD")
REMOTE_BRANCH=$(awk '$1 == "ref:" && $3 == "HEAD" {sub("^refs/heads/", "", $2); print $2}' <<<"$REMOTE_HEAD")
if [[ -z "$REMOTE_TIP" ]]; then
    echo "Cannot read origin's default branch tip (git ls-remote --symref origin HEAD)." >&2
    exit 1
fi
if [[ "$(git rev-parse HEAD)" != "$REMOTE_TIP" ]]; then
    echo "HEAD is not the tip of origin's default branch${REMOTE_BRANCH:+ ${REMOTE_BRANCH}}: check out and pull it." >&2
    exit 1
fi
if [[ -n "$(git status --porcelain --untracked-files=all --ignore-submodules=none)" ]]; then
    echo "The working tree is not clean (untracked files included): commit or stash." >&2
    exit 1
fi

LATEST_TAG=$(latest_release_tag)

# An rc gets its number incremented, a final its patch; no tag, no suggestion.
SUGGESTION=
if [[ "$LATEST_TAG" =~ $TAG_RE ]]; then
    if [[ -n "${BASH_REMATCH[5]}" ]]; then
        SUGGESTION="${BASH_REMATCH[1]}${BASH_REMATCH[2]}.${BASH_REMATCH[3]}.${BASH_REMATCH[4]}${BASH_REMATCH[6]}$((BASH_REMATCH[7] + 1))"
    else
        SUGGESTION="${BASH_REMATCH[1]}${BASH_REMATCH[2]}.${BASH_REMATCH[3]}.$((BASH_REMATCH[4] + 1))"
    fi
fi

# REVISION (set by a release script) skips the prompt.
VERSION=${REVISION:-}
if [[ -z "$VERSION" ]]; then
    # End of input (Ctrl-D, or no terminal) is no answer, not the suggestion.
    read -r -p "Enter the new tag${SUGGESTION:+ [${SUGGESTION}]}: " VERSION || [[ -n "$VERSION" ]] || {
        echo "No answer; nothing tagged." >&2
        exit 1
    }
    VERSION=${VERSION:-$SUGGESTION}
fi

if [[ ! "$VERSION" =~ $TAG_RE ]]; then
    echo "Refusing tag '${VERSION}'${REVISION:+ (from REVISION)}: a release tag is ${TAG_SHAPE}." >&2
    exit 1
fi

echo "Creating and pushing tag ${VERSION}..."

git tag -a -s "${VERSION}" -m "Release ${VERSION}" "$REMOTE_TIP"
git push origin "${VERSION}" || {
    git tag -d "${VERSION}" >/dev/null
    echo "Push failed; the local tag ${VERSION} is deleted again." >&2
    exit 1
}

echo "Tagging operation completed."
