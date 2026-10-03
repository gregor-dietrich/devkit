#!/bin/bash

set -euo pipefail

echo "Starting branch operation..."

cd "$PROJECT_ROOT"

read -r -p "Enter the target branch to create/reset: " TARGET_BRANCH

if [[ -z "$TARGET_BRANCH" ]]; then
    echo "No target branch entered. Exiting."
    exit 1
fi

read -r -p "Enter the source branch to create/reset ${TARGET_BRANCH} from/to [origin/main]: " SOURCE_BRANCH
SOURCE_BRANCH=${SOURCE_BRANCH:-origin/main}

git fetch

if git show-ref --verify --quiet "refs/heads/${TARGET_BRANCH}" || git show-ref --verify --quiet "refs/remotes/origin/${TARGET_BRANCH}"; then
    git checkout "${TARGET_BRANCH}"
    git reset --hard "${SOURCE_BRANCH}"
else
    git checkout -b "${TARGET_BRANCH}" "${SOURCE_BRANCH}"
fi

if git ls-remote --exit-code --heads origin "${TARGET_BRANCH}" >/dev/null 2>&1; then
    git push --force-with-lease origin "${TARGET_BRANCH}"
else
    git push -u origin "${TARGET_BRANCH}"
fi

echo "Branch ${TARGET_BRANCH} pushed successfully."
echo "Branch operation completed."
