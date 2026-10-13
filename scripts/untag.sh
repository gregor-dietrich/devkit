#!/bin/bash

set -euo pipefail

echo "Starting untagging operation..."

cd "$PROJECT_ROOT"

git fetch origin

# shellcheck source=SCRIPTDIR/lib/release_tag.sh
. "$DEVKIT/scripts/lib/release_tag.sh"
LATEST_TAG=$(latest_release_tag)

# End of input (Ctrl-D, or no terminal) is no answer, not the default.
read -r -p "Enter the tag to delete${LATEST_TAG:+ [${LATEST_TAG}]}: " VERSION || [[ -n "$VERSION" ]] || {
    echo "No answer; nothing deleted." >&2
    exit 1
}
VERSION=${VERSION:-$LATEST_TAG}
if [[ -z "$VERSION" ]]; then
    echo "No tag given; nothing deleted." >&2
    exit 1
fi

echo "Deleting tag ${VERSION}..."

if git show-ref --verify --quiet "refs/tags/${VERSION}"; then
    git tag -d "$VERSION"
    echo "Tag ${VERSION} deleted locally."
else
    echo "Tag ${VERSION} not found locally."
fi

if git ls-remote --exit-code --tags origin "refs/tags/${VERSION}" >/dev/null; then
    git push origin ":refs/tags/${VERSION}"
    echo "Tag ${VERSION} deleted from remote."
else
    echo "Tag ${VERSION} not found on remote."
fi

echo "Untagging operation completed."
