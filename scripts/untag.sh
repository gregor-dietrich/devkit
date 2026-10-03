#!/bin/bash

set -euo pipefail

echo "Starting untagging operation..."

cd "$PROJECT_ROOT"

git fetch

LATEST_VERSION=$(git for-each-ref --count=1 --sort=-version:refname \
    --format='%(refname:lstrip=2)' refs/tags)
LATEST_VERSION=${LATEST_VERSION:-1.0.0-SNAPSHOT}

read -r -p "Enter the tag to delete [${LATEST_VERSION}]: " VERSION
VERSION=${VERSION:-$LATEST_VERSION}

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
