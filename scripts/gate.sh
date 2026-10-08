#!/bin/bash
# make gate: run the push gate (`make lint-repo test`, the stages
# scripts/hooks/pre-push.sh runs) and, when it passes, record HEAD in the git
# directory (`git rev-parse --git-path devkit-verified-head`, per worktree).
# pre-push skips a HEAD it recorded while the tree is still strictly clean
# (docs/contract.md, Git hooks). A record is made only when nothing could make
# the verdict about another tree than the commit HEAD names:
#   - the project is the git top level, whose gate pre-push runs;
#   - HEAD exists, and the ref backend lets us see it move (files, with a
#     HEAD reflog), since a run that moved HEAD verified no single commit;
#   - the tree was strictly clean at the start and at the end, so the verdict
#     is about the commit, not about edits or untracked files;
#   - no environment variable that can skip or deselect tests is set.
# Recording never changes the exit status: it is the stages'. bash 3.2 (macOS).
set -uo pipefail

cd "$PROJECT_ROOT" || exit 1

if [[ -n "${ONLY-}" ]]; then
    echo "ERROR: make gate runs the whole push gate and records the result; unset ONLY (it is '$ONLY')." >&2
    exit 2
fi

# strictly_clean: no change, untracked file or dirty submodule (ignored files
# are fine) and no assume-unchanged or skip-worktree entry; a failing git
# command is not clean. Duplicated in scripts/hooks/pre-push.sh, which stays
# self-contained. No `ls-files | grep -q`: grep's early exit would SIGPIPE it.
strictly_clean() {
    local status files
    status=$(git status --porcelain --untracked-files=all --ignore-submodules=none 2> /dev/null) || return 1
    [[ -z "$status" ]] || return 1
    files=$(git ls-files -v -- :/ 2> /dev/null) || return 1
    ! grep -q '^[a-zS]' <<< "$files"
}

reasons=""
why() { reasons="${reasons:+$reasons; }$1"; }

record="" marker="" head=""
trap '[[ -z "$marker" ]] || rm -f "$marker"' EXIT
if git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
    record=$(git rev-parse --git-path devkit-verified-head)
    head_path=$(git rev-parse --git-path HEAD)
    log_path=$(git rev-parse --git-path logs/HEAD)
    rm -f "$record" 2> /dev/null # a run in progress or a failing run leaves none
    head=$(git rev-parse --verify --quiet HEAD)
    [[ -n "$head" ]] || why "HEAD has no commit"
    strictly_clean || why "the tree was not clean at the start"
    [[ "$(git config --get extensions.refStorage)" != [Rr][Ee][Ff][Tt][Aa][Bb][Ll][Ee] ]] ||
        why "the reftable ref backend (a HEAD move could not be detected)"
    [[ -f "$log_path" ]] || why "no HEAD reflog (core.logAllRefUpdates), so a HEAD move could not be detected"
    # pre-push gates the top level's project, not a nested one's.
    [[ "$(cd "$(git rev-parse --show-toplevel)" && pwd -P)" == "$(pwd -P)" ]] ||
        why "the project is not the git top level, whose gate pre-push runs"
else
    why "this is not a git work tree"
fi
[[ -z "${MAVEN_ARGS-}" ]] || why "MAVEN_ARGS is set (it can skip tests)"
for var in MAVEN_OPTS JAVA_TOOL_OPTIONS JDK_JAVA_OPTIONS; do # JVM options: -D sets a system property
    [[ "${!var-}" != *-D* ]] || why "$var holds a -D (it can skip tests)"
done
[[ -z "${PYTEST_ADDOPTS-}" ]] || why "PYTEST_ADDOPTS is set (it can deselect tests)"
# Beside the record (same filesystem and timestamp granularity): the files
# touched after it are what moved HEAD during the run.
[[ -n "$reasons" ]] || marker=$(mktemp "$record.XXXXXX") || why "no marker could be created"

# Cleared, an outer `make -i/-k/-n/-o` cannot reach a stage, nor can makefiles
# MAKEFILES adds. A command-line VAR=value still reaches the stages' environment.
env -u MAKEFLAGS -u MFLAGS -u MAKELEVEL -u MAKEFILES make --no-print-directory lint-repo test
rc=$?

if [[ "$rc" -eq 0 && -z "$reasons" ]]; then
    strictly_clean || why "the tree changed during the run"
    # find -newer, not -nt: bash 3.2 compares whole seconds. A failing find
    # counts as a move. This also catches A -> B -> A, which keeps the SHA.
    moved=$(find -H "$head_path" "$log_path" -newer "$marker" 2>&1) || moved=failed
    [[ -z "$moved" && "$(git rev-parse --verify --quiet HEAD)" == "$head" ]] || why "HEAD moved during the run"
fi

if [[ "$rc" -ne 0 ]]; then
    :
elif [[ -n "$reasons" ]]; then
    echo "NOTE: make gate passed but did not record HEAD: $reasons."
elif [[ ! -d "$record" ]] && { echo "$head" > "$marker" && mv -f "$marker" "$record"; } 2> /dev/null; then
    echo "make gate: recorded ${head:0:12} as verified; pre-push skips it while the tree stays clean."
else
    echo "WARNING: make gate passed but could not record HEAD in $record." >&2
fi
exit "$rc"
