#!/bin/bash

set -euo pipefail

echo "Starting rebase operation..."

cd "$PROJECT_ROOT"

git fetch

read -r -p "Enter the branch/commit to rebase against [origin/main]: " REBASE_TARGET
REBASE_TARGET=${REBASE_TARGET:-origin/main}

echo "Rebasing against: $REBASE_TARGET"
git rebase "$REBASE_TARGET"

echo "Force pushing..."
git push --force-with-lease

echo "Rebase operation completed."
