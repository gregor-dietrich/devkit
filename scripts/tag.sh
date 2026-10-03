#!/bin/bash

set -euo pipefail

echo "Starting tagging operation..."

cd "$PROJECT_ROOT"

git fetch

LATEST_TAG=$(git for-each-ref --count=1 --sort=-version:refname \
    --format='%(refname:lstrip=2)' refs/tags)
LATEST_TAG=${LATEST_TAG:-1.0.0-SNAPSHOT}

# Suggest the latest tag with its last numeric component incremented.
if [[ "$LATEST_TAG" =~ ^(([0-9]+\.)*)([0-9]+)(.*)$ ]]; then
    LATEST_VERSION="${BASH_REMATCH[1]}$((BASH_REMATCH[3] + 1))${BASH_REMATCH[4]}"
else
    LATEST_VERSION="$LATEST_TAG"
fi

# REVISION (set by a release script) skips the prompt.
VERSION=${REVISION:-}
if [[ -z "$VERSION" ]]; then
    read -r -p "Enter the new tag [${LATEST_VERSION}]: " VERSION
    VERSION=${VERSION:-$LATEST_VERSION}
fi

echo "Creating and pushing tag ${VERSION}..."

git tag -a -s "${VERSION}" -m "Release ${VERSION}"
git push origin "${VERSION}"

echo "Tagging operation completed."
