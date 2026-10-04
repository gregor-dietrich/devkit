#!/usr/bin/env bash
# Tests for scripts/lib/select_modules.sh: each case sources it in a subshell
# with a profile and an ONLY, and compares what it exports, or how it fails.
# Prints PASS/FAIL per case.
set -euo pipefail

lib=$(cd "$(dirname "$0")/.." && pwd)/scripts/lib/select_modules.sh
fails=0

# expect MODULES FRONTEND_DIR ONLY WANT: WANT is "ONLY|SELECTED|FRONTEND_SELECTED"
# as exported, or the error and the sourcing script's exit status.
expect() {
  local got
  got=$(MODULES=$1 FRONTEND_DIR=$2 ONLY=$3 bash -c 'set -euo pipefail; . "$0"
    echo "$ONLY|$SELECTED|$FRONTEND_SELECTED"' "$lib" 2>&1) || got+=" (exit $?)"
  if [[ $got == "$4" ]]; then
    echo "PASS MODULES='$1' FRONTEND_DIR='$2' ONLY='$3'"
  else
    echo "FAIL MODULES='$1' FRONTEND_DIR='$2' ONLY='$3': got '$got', want '$4'"
    fails=$((fails + 1))
  fi
}

expect "api gui" gui "" "|api gui|true"
expect "api gui" gui "api" "api|api|false"
expect "api gui" gui "gui/" "gui|gui|true"
expect "api gui" gui "./gui,:api" "gui,api|gui api|true"
expect "api gui" "" "gui" "gui|gui|false"
expect "" "" "" "|.|false"
expect "" . "" "|.|true"
expect "api gui" gui "app-api" "ERROR: ONLY entry 'app-api' is not one of MODULES (api gui). (exit 1)"
expect "api gui" gui "api," "api|api|false"
expect "api gui" gui ",api" "ERROR: ONLY entry '' is not one of MODULES (api gui). (exit 1)"
expect "" "" "api" "ERROR: ONLY entry 'api' is not one of MODULES (empty: a monolith). (exit 1)"
expect "api gui" gui "api gui" "ERROR: ONLY api\\ gui contains whitespace; separate MODULES entries with commas only. (exit 1)"
expect "api gui" gui $'api\ngui' "ERROR: ONLY \$'api\\ngui' contains whitespace; separate MODULES entries with commas only. (exit 1)"
expect "api gui" gui "api, gui" "ERROR: ONLY api\\,\\ gui contains whitespace; separate MODULES entries with commas only. (exit 1)"
expect "api gui" gui "gui,gui/,api,:gui" "gui,api|gui api|true"

[[ $fails == 0 ]]
