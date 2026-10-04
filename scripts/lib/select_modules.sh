#!/bin/bash

# Sourced by every script that acts on the ONLY selection, devkit's and a consumer's own, instead of
# parsing ONLY itself. ONLY names MODULES entries, comma-separated, with no whitespace. Maven's -pl
# also takes ./<dir>, <dir>/ and :<dir>, so each entry is normalized to its MODULES spelling and kept
# once; an entry that names no module, or whitespace anywhere in ONLY, fails the sourcing script.
# Exports:
#   ONLY               the normalized selection; empty selects the whole reactor
#   SELECTED           the selected module directories, space-separated; "." for a monolith
#   FRONTEND_SELECTED  true when FRONTEND_DIR is set and part of the selection, else false

select_modules() {
    local entry entries=() kept=,
    # A space would let one entry span two MODULES words; read would drop every line after the first.
    [[ "${ONLY:-}" != *[[:space:]]* ]] || {
        printf 'ERROR: ONLY %q contains whitespace; separate MODULES entries with commas only.\n' "$ONLY" >&2
        exit 1
    }
    IFS=, read -ra entries <<< "${ONLY:-}"
    # The +-guard: bash before 4.4 calls an empty array unbound under set -u.
    for entry in ${entries[@]+"${entries[@]}"}; do
        entry=${entry#./} entry=${entry#:} entry=${entry%/}
        [[ " ${MODULES:-} " == *" $entry "* ]] || {
            echo "ERROR: ONLY entry '$entry' is not one of MODULES (${MODULES:-empty: a monolith})." >&2
            exit 1
        }
        [[ $kept == *",$entry,"* ]] || kept+="$entry,"
    done
    kept=${kept#,} ONLY=${kept%,}
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
