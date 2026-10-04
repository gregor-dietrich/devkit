#!/bin/bash

# Sourced by every script that acts on the ONLY selection, devkit's and a consumer's own, instead of
# parsing ONLY itself. ONLY names MODULES entries, comma-separated. Maven's -pl also takes ./<dir>,
# <dir>/ and :<dir>, so each entry is normalized to its MODULES spelling; one that names no module
# fails the sourcing script. Exports:
#   ONLY               the normalized selection; empty selects the whole reactor
#   SELECTED           the selected module directories, space-separated; "." for a monolith
#   FRONTEND_SELECTED  true when FRONTEND_DIR is set and part of the selection, else false

select_modules() {
    local entry entries=() normalized=()
    IFS=, read -ra entries <<< "${ONLY:-}"
    for entry in "${entries[@]}"; do
        entry=${entry#./} entry=${entry#:} entry=${entry%/}
        [[ " ${MODULES:-} " == *" $entry "* ]] || {
            echo "ERROR: ONLY entry '$entry' is not one of MODULES (${MODULES:-empty: a monolith})." >&2
            exit 1
        }
        normalized+=("$entry")
    done
    ONLY=$(IFS=,; echo "${normalized[*]}")
    SELECTED=${ONLY//,/ }
    SELECTED=${SELECTED:-${MODULES:-.}}
    if [[ -n "${FRONTEND_DIR:-}" && ( -z "$ONLY" || ",$ONLY," == *",$FRONTEND_DIR,"* ) ]]; then
        FRONTEND_SELECTED=true
    else
        FRONTEND_SELECTED=false
    fi
    export ONLY SELECTED FRONTEND_SELECTED
}
select_modules
