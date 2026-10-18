#!/bin/bash

# Sourced by the scripts/python/*.sh after they cd to $PROJECT_ROOT. Sets VENV, the project's
# .venv that make install syncs from uv.lock, and fails without its python. venv_tool NAME
# [DIST] prints the path of the .venv's NAME executable, or fails naming DIST (default NAME),
# the dev-group entry that provides it. Assign before use, so set -e sees a failure:
#   ruff=$(venv_tool ruff)
# venv_synced confirms with uv that the .venv matches uv.lock, or prints uv's report and the remedy
# and exits 1; it needs UV_CMD, from get_uv.sh.

VENV=$PWD/.venv
[[ -x $VENV/bin/python ]] || {
    echo "ERROR: no .venv; run make install." >&2
    exit 1
}

venv_tool() {
    [[ -x $VENV/bin/$1 ]] || {
        echo "ERROR: .venv has no $1; add ${2:-$1} to the dev dependency group, then uv lock and make install." >&2
        exit 1
    }
    printf '%s\n' "$VENV/bin/$1"
}

venv_synced() {
    local sync_out
    if ! sync_out=$("$UV_CMD" sync --check --frozen --offline --all-packages --all-extras 2>&1); then
        echo "ERROR: uv cannot confirm .venv matches uv.lock. It reported:" >&2
        echo "    ${sync_out//$'\n'/$'\n'    }" >&2
        echo "If that is drift, run make install; an unreadable uv.lock or unwritable cache is its own fix." >&2
        exit 1
    fi
}
