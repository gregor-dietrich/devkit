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
#   - git ignores none of the .mvn/ files Maven reads, which a tree that is
#     clean by git's account would hide;
#   - no environment variable, mavenrc file, user-level core extensions file or
#     settings.xml profile property that can skip or deselect tests is set.
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

# ignored_mvn: sets mvn_ignored to the ignored ones (a line each) among the three
# files under .mvn/ Maven reads whether git tracks them or not (not
# .mvn/wrapper/), which strictly_clean counts as clean. Fails when git does.
# Duplicated in scripts/hooks/pre-push.sh, which only warns.
ignored_mvn() {
    mvn_ignored=$(git ls-files --others --ignored --exclude-standard -- .mvn/maven.config .mvn/extensions.xml .mvn/jvm.config 2> /dev/null)
}

# strip_comments TEXT: TEXT without its XML comments (<!-- ... -->, which may
# span lines); an unterminated comment drops the rest. Duplicated in
# scripts/hooks/pre-push.sh. Pure parameter expansion, for bash 3.2.
strip_comments() {
    local s=$1 kept=""
    while [[ "$s" == *'<!--'* ]]; do
        kept="$kept${s%%'<!--'*}"
        s=${s#*'<!--'}
        if [[ "$s" == *'-->'* ]]; then s=${s#*'-->'}; else s=""; fi
    done
    printf '%s' "$kept$s"
}

# sets_properties FILE: FILE is a readable file that, comments aside, holds a
# <properties element. In a Maven settings.xml that occurs only in a profile.
sets_properties() {
    local content
    [[ -f "$1" && -r "$1" ]] || return 1
    content=$(<"$1") || return 1
    content=$(strip_comments "$content")
    [[ "$content" == *'<properties'* ]]
}

# trim TEXT: TEXT without leading and trailing whitespace. Duplicated in
# scripts/hooks/pre-push.sh.
trim() {
    local s=$1
    s=${s#"${s%%[![:space:]]*}"}
    printf '%s' "${s%"${s##*[![:space:]]}"}"
}

# activates_project_profile FILE: FILE is a readable file that, comments aside,
# holds an <activeProfile> whose id is not the text of an <id> element in its
# <profiles> section: Maven activates a profile of that id from the project's
# POM, which can skip tests. One naming a profile of the file itself is covered
# by sets_properties. Every <id> in the section counts as defined, so a
# repository id inside a profile could hide a same-named activeProfile, which
# only a deliberate setup reaches. No <profiles> section: every activeProfile
# counts. Duplicated in scripts/hooks/pre-push.sh.
activates_project_profile() {
    local content rest id defined=""
    [[ -f "$1" && -r "$1" ]] || return 1
    content=$(<"$1") || return 1
    content=$(strip_comments "$content")
    if [[ "$content" == *'<profiles>'* ]]; then
        rest=${content#*'<profiles>'}
        rest=${rest%%'</profiles>'*}
        while [[ "$rest" == *'<id>'* ]]; do
            rest=${rest#*'<id>'}
            id=$(trim "${rest%%'</id>'*}")
            defined="$defined"$'\n'"$id"$'\n'
        done
    fi
    rest=$content
    while [[ "$rest" == *'<activeProfile>'* ]]; do
        rest=${rest#*'<activeProfile>'}
        id=$(trim "${rest%%'</activeProfile>'*}")
        [[ "$defined" == *$'\n'"$id"$'\n'* ]] || return 0
    done
    return 1
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
    ignored_mvn || why "git could not list the ignored files under .mvn/"
    [[ -z "$mvn_ignored" ]] || why "git ignores .mvn/ files Maven reads: ${mvn_ignored//$'\n'/, } (they can skip tests)"
    [[ "$(git config --get extensions.refStorage)" != [Rr][Ee][Ff][Tt][Aa][Bb][Ll][Ee] ]] ||
        why "the reftable ref backend (a HEAD move could not be detected)"
    [[ -f "$log_path" ]] || why "no HEAD reflog (core.logAllRefUpdates), so a HEAD move could not be detected"
    # pre-push gates the top level's project, not a nested one's.
    [[ "$(cd "$(git rev-parse --show-toplevel)" && pwd -P)" == "$(pwd -P)" ]] ||
        why "the project is not the git top level, whose gate pre-push runs"
else
    why "this is not a git work tree"
fi
# These variables and files are listed again in scripts/hooks/pre-push.sh, which
# warns on the same ones; keep the two in step. tests/run.sh's launcher_inputs
# fails when the pinned bin/mvn reads a variable it does not account for.
[[ -z "${MAVEN_ARGS-}" ]] || why "MAVEN_ARGS is set (it can skip tests)"
# MAVEN_BASEDIR replaces the project directory .mvn/ and the parent's gate
# configurations are read from.
[[ -z "${MAVEN_BASEDIR-}" ]] || why "MAVEN_BASEDIR is set (it moves .mvn/ and the gate configurations, which can skip tests)"
# MAVEN_DEBUG_OPTS: any value counts. It is mvnDebug's debugger option and has
# no ordinary use under mvn.
[[ -z "${MAVEN_DEBUG_OPTS-}" ]] || why "MAVEN_DEBUG_OPTS is set (the launcher hands it to java, which can skip tests)"
# JVM options, which the launcher of devkit's Maven or its JVM reads. A word that
# starts with -D sets a system property, and @argfile, -XX:VMOptionsFile= and
# -Xoptionsfile= (OpenJ9) read options (a -D among them) from a file.
# -XX:Flags= reads options from a flags file. -javaagent:, -agentpath:,
# -agentlib: and -Xrun load code into Maven's JVM, like the user-level core
# extensions counted below. An option that ends java without running the main
# class (-version, -fullversion, --help, --dry-run, --list-modules,
# -Xshare:dump, -XX:AOTMode=create, -XX:+PrintFlagsInitial ...; the list was
# checked against JDK 25) exits 0 with no test run, and -jar, -m and --module
# replace the main class. A word of the form -...:help or -...=help (-Xlog:help)
# also exits, unless it is already reported as an option above (-Dx=help). Java
# strips quotes inside its own variables (JDK_JAVA_OPTIONS, JAVA_TOOL_OPTIONS
# ...); in MAVEN_OPTS, which the launcher word-splits, a quote stays literal, so
# removing every quote first can only over-count. Words are matched whole, at
# the start of the value or after whitespace, so a negated -XX:-D... flag or
# -showversion does not count. Every variable gets the same test; a JVM that
# rejects an option fails loudly. The message names the option, never a value
# (a help word is named whole: its value is the literal help). A new option goes
# into file_re or exit_re. Duplicated in scripts/hooks/pre-push.sh.
file_re='-D|@|-XX:VMOptionsFile=|-XX:Flags=|-Xoptionsfile=|-javaagent:|-agentpath:|-agentlib:|-Xrun'
exit_re='-version|--version|-fullversion|--full-version|-Xinternalversion|-help|--help|-h|-[?]|-X|--help-extra|--dry-run|--list-modules|-d|--describe-module|--validate-modules|-jar|-m|--module|-Xshare:dump|-XX:AOTMode=create|-XX:[+]PrintFlagsInitial|-XX:[+]PrintSharedArchiveAndExit|-XX:[+]JVMCIPrintProperties'
jvm_re='(^|[[:space:]])(('"$file_re"')|('"$exit_re"')([[:space:]=]|$))'
help_re='(^|[[:space:]])(-[^[:space:]]*[:=]help)([[:space:]]|$)'
dq='"' sq="'"
# Prints the option $1 holds, or nothing. Call it in $( ): LC_ALL=C there keeps
# a stray byte from making regexec fail (no match), without changing the locale
# of the stages. BASH_REMATCH[3] is a file_re option, [4] an exit_re one.
jvm_option() {
    LC_ALL=C
    local t=${1//"$dq"/}
    t=${t//"$sq"/}
    if [[ $t =~ $jvm_re ]]; then
        t=${BASH_REMATCH[4]:-${BASH_REMATCH[3]}}
        echo "${t%[:=]}"
    elif [[ $t =~ $help_re ]]; then
        echo "${BASH_REMATCH[2]}"
    fi
}
# bash 3.2 reads a regex it cannot compile as no match, so the screen is checked
# on known positives first.
if [[ $(jvm_option '-"D"x') == -D && $(jvm_option "-Xmx1g -'version'") == -version &&
    $(jvm_option '-javaagent:/x') == -javaagent && $(jvm_option '-Xlog:help') == -Xlog:help &&
    -z $(jvm_option '-Xmx1g') ]]; then
    for var in MAVEN_OPTS JAVA_TOOL_OPTIONS JDK_JAVA_OPTIONS _JAVA_OPTIONS OPENJ9_JAVA_OPTIONS IBM_JAVA_OPTIONS; do
        opt=$(jvm_option "${!var-}")
        [[ -z $opt ]] || why "$var holds ${opt/#@/@argfile} (it can skip tests)"
    done
else
    why "the JVM options screen does not work in this bash"
fi
[[ -z "${PYTEST_ADDOPTS-}" ]] || why "PYTEST_ADDOPTS is set (it can deselect tests)"
# Maven's launcher sources these shell files unless MAVEN_SKIP_RC is non-empty,
# and a settings.xml profile's <properties> can set skipTests like a -D.
if [[ -z "${MAVEN_SKIP_RC-}" ]]; then
    for rcfile in /usr/local/etc/mavenrc /etc/mavenrc "${HOME-}/.mavenrc"; do
        [[ ! -e "$rcfile" ]] || why "$rcfile exists, and Maven runs it (it can skip tests)"
    done
fi
! sets_properties "${HOME-}/.m2/settings.xml" || why "${HOME-}/.m2/settings.xml sets profile properties (they can skip tests)"
! activates_project_profile "${HOME-}/.m2/settings.xml" || why "${HOME-}/.m2/settings.xml activates a profile it does not define (a project profile can skip tests)"
# Maven loads core extensions (code in its JVM, e.g. one that restores test
# results) from the user's file whatever it holds, and MAVEN_SKIP_RC does not
# stop it, but only a regular file is loaded (-f follows symlinks). Duplicated
# in scripts/hooks/pre-push.sh.
[[ ! -f "${HOME-}/.m2/extensions.xml" ]] || why "${HOME-}/.m2/extensions.xml exists, and Maven loads its core extensions (they can skip tests)"
# Beside the record (same filesystem and timestamp granularity): the files
# touched after it are what moved HEAD during the run.
[[ -n "$reasons" ]] || marker=$(mktemp "$record.XXXXXX") || why "no marker could be created"

# Cleared, an outer `make -i/-k/-n/-o` cannot reach a stage, nor can makefiles
# MAKEFILES adds. A command-line VAR=value still reaches the stages' environment.
env -u MAKEFLAGS -u MFLAGS -u GNUMAKEFLAGS -u MAKELEVEL -u MAKEFILES make --no-print-directory lint-repo test
rc=$?

if [[ "$rc" -eq 0 && -z "$reasons" ]]; then
    strictly_clean || why "the tree changed during the run"
    # Tree state, like strictly_clean, so checked at both ends. The environment
    # cannot change under the run and nothing it does writes the home-directory
    # files, so those checks above run at the start only.
    ignored_mvn || why "git could not list the ignored files under .mvn/"
    [[ -z "$mvn_ignored" ]] || why "git ignores .mvn/ files Maven reads that appeared during the run: ${mvn_ignored//$'\n'/, } (they can skip tests)"
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
