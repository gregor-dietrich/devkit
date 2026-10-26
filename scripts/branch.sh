#!/bin/bash

set -euo pipefail

echo "Starting branch operation..."

cd "$PROJECT_ROOT"

read -r -p "Enter the target branch to create/reset: " TARGET_BRANCH

if [[ -z "$TARGET_BRANCH" ]]; then
    echo "No target branch entered. Exiting." >&2
    exit 1
fi

read -r -p "Enter the source branch to create/reset ${TARGET_BRANCH} from/to [origin/main]: " SOURCE_BRANCH
SOURCE_BRANCH=${SOURCE_BRANCH:-origin/main}

git fetch

if git show-ref --verify --quiet "refs/heads/${TARGET_BRANCH}" || git show-ref --verify --quiet "refs/remotes/origin/${TARGET_BRANCH}"; then
    if [[ -n "$(git status --porcelain --untracked-files=no --ignore-submodules=none)" ]]; then
        echo "Uncommitted changes in the working tree would be lost by the reset to ${SOURCE_BRANCH}; commit or stash them first." >&2
        exit 1
    fi
    git checkout "${TARGET_BRANCH}"
    # --keep refuses where an untracked file is in the way, which --hard would overwrite
    git reset --keep "${SOURCE_BRANCH}"
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
