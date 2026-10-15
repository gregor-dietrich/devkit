#!/bin/bash
# The push gate: `make lint-repo test`. scripts/hooks.sh renders this file
# into the pre-push hook as a self-contained copy and runs it with the hook's
# name prepended to git's arguments. Skip it once with `git push --no-verify`;
# CI stays the backstop.
#
# It gates the work tree at HEAD, not the commits git names on stdin: it says
# so when a pushed commit is not HEAD, or when the tree is dirty. It skips the
# gate for a HEAD that `make gate` passed (scripts/gate.sh recorded it) while
# the tree is still strictly clean.
#
# It never narrows the gate: it unsets ONLY and clears the outer make's flags,
# as `make gate` does. It warns, but does not refuse, on the variables and files
# (an ignored .mvn/ file Maven reads among them) `make gate` will not record
# under, since those are often set on purpose. That list is duplicated in
# scripts/gate.sh.
#
# git sends the ref lines on one stdin, which an up-to-date push leaves empty.
# Installed as `pre-push` itself, zero lines therefore means nothing to push.
# Under any other name (pre-push.devkit called from someone else's hook, or
# pre-push.legacy/.old run by a hook manager) that hook may have read stdin
# first, so zero lines runs the gate. bash 3.2 (macOS): no mapfile.

# strictly_clean: no change, untracked file or dirty submodule (ignored files
# are fine) and no assume-unchanged or skip-worktree entry; a failing git
# command is not clean. Duplicated in scripts/gate.sh; this file stays
# self-contained. No `ls-files | grep -q`: grep's early exit would SIGPIPE it.
strictly_clean() {
    local status files
    status="$(git status --porcelain --untracked-files=all --ignore-submodules=none 2> /dev/null)" || return 1
    [[ -z "$status" ]] || return 1
    files="$(git ls-files -v -- :/ 2> /dev/null)" || return 1
    ! grep -q '^[a-zS]' <<< "$files"
}

# ignored_mvn: sets mvn_ignored to the ignored ones (a line each) among the three
# files under .mvn/ Maven reads whether git tracks them or not (not
# .mvn/wrapper/), which strictly_clean counts as clean. Fails when git does.
# Duplicated in scripts/gate.sh, which refuses to record instead of warning.
ignored_mvn() {
    mvn_ignored=$(git ls-files --others --ignored --exclude-standard -- .mvn/maven.config .mvn/extensions.xml .mvn/jvm.config 2> /dev/null)
}

# strip_comments TEXT: TEXT without its XML comments (<!-- ... -->, which may
# span lines); an unterminated comment drops the rest. Duplicated in
# scripts/gate.sh. Pure parameter expansion, for bash 3.2.
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
# scripts/gate.sh.
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
# counts. Duplicated in scripts/gate.sh.
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

root="$(git rev-parse --show-toplevel)" || exit 1
# See pre-commit.sh: the gate sees the repository as a plain shell would.
while IFS= read -r var; do
    unset "$var"
done < <(git rev-parse --local-env-vars)
cd "$root" || exit 1

head="$(git rev-parse --verify --quiet HEAD)"
# One "<local ref> <local sha> <remote ref> <remote sha>" line per ref; an
# all-zero local sha is a deletion, which carries no commit to gate. A tag is
# peeled to the commit it names.
lines=0
pushed=0
not_head=""
while read -r local_ref local_sha _ _; do
    [[ -n "$local_sha" ]] || continue
    lines=$((lines + 1))
    [[ ! "$local_sha" =~ ^0+$ ]] || continue
    pushed=1
    commit="$(git rev-parse --verify --quiet "$local_sha^{commit}")" || commit="$local_sha"
    [[ "$commit" == "$head" ]] || not_head="$not_head $local_ref"
done

if [[ "$lines" -eq 0 ]]; then
    [[ "${0##*/}" != "pre-push" ]] || exit 0
    echo "pre-push: git sent no refs (another hook may have read them); gating HEAD"
elif [[ "$pushed" -eq 0 ]]; then
    echo "pre-push: nothing but deletions, no commit to gate"
    exit 0
fi

if [[ -n "$not_head" ]]; then
    echo "WARNING: pushing$not_head, which is not HEAD. The gate checks the work"
    echo "         tree at HEAD, so its verdict is not about what you push."
fi
if [[ -n "$(git status --porcelain 2> /dev/null)" ]]; then
    echo "WARNING: the work tree is dirty, so the gate below checks your"
    echo "         uncommitted edits too, not just the commits being pushed."
fi

verified="$(git rev-parse --git-path devkit-verified-head)"
recorded=""
[[ ! -f "$verified" ]] || read -r recorded < "$verified" || true
if [[ -n "$head" && "$recorded" == "$head" ]] && strictly_clean; then
    echo "pre-push: HEAD ${head:0:12} passed 'make gate' on this clean tree; skipping the gate"
    exit 0
fi

# ONLY reaches every recipe (common.mk exports it): an ambient one would narrow
# the gate unseen, so the hook says so and runs the whole gate.
[[ -z "${ONLY-}" ]] || echo "pre-push: ignoring ONLY (it is '$ONLY'); the push gate is never narrowed"
[[ -z "${MAVEN_ARGS-}" ]] || echo "WARNING: MAVEN_ARGS is set (it can skip tests)."
[[ -z "${MAVEN_BASEDIR-}" ]] || echo "WARNING: MAVEN_BASEDIR is set (it moves .mvn/ and the gate configurations, which can skip tests)."
# Any value counts, as in gate.sh.
[[ -z "${MAVEN_DEBUG_OPTS-}" ]] || echo "WARNING: MAVEN_DEBUG_OPTS is set (the launcher hands it to java, which can skip tests)."
# JVM options, as in gate.sh (see there for what counts; the definitions are
# duplicated: this hook stays self-contained). A new option goes into file_re or
# exit_re.
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
if [[ $(jvm_option '-"D"x') == -D && $(jvm_option "-Xmx1g -'version'") == -version &&
    $(jvm_option '-javaagent:/x') == -javaagent && $(jvm_option '-Xlog:help') == -Xlog:help &&
    -z $(jvm_option '-Xmx1g') ]]; then
    for var in MAVEN_OPTS JAVA_TOOL_OPTIONS JDK_JAVA_OPTIONS _JAVA_OPTIONS OPENJ9_JAVA_OPTIONS IBM_JAVA_OPTIONS; do
        opt=$(jvm_option "${!var-}")
        [[ -z $opt ]] || echo "WARNING: $var holds ${opt/#@/@argfile} (it can skip tests)."
    done
else
    echo "WARNING: the JVM options screen does not work in this bash; the gate runs anyway."
fi
[[ -z "${PYTEST_ADDOPTS-}" ]] || echo "WARNING: PYTEST_ADDOPTS is set (it can deselect tests)."
# Maven sources these unless MAVEN_SKIP_RC is non-empty; as in gate.sh.
if [[ -z "${MAVEN_SKIP_RC-}" ]]; then
    for rcfile in /usr/local/etc/mavenrc /etc/mavenrc "${HOME-}/.mavenrc"; do
        [[ ! -e "$rcfile" ]] || echo "WARNING: $rcfile exists, and Maven runs it (it can skip tests)."
    done
fi
! sets_properties "${HOME-}/.m2/settings.xml" || echo "WARNING: ${HOME-}/.m2/settings.xml sets profile properties (they can skip tests)."
! activates_project_profile "${HOME-}/.m2/settings.xml" || echo "WARNING: ${HOME-}/.m2/settings.xml activates a profile it does not define (a project profile can skip tests)."
# Any regular file counts, MAVEN_SKIP_RC or not; as in gate.sh.
[[ ! -f "${HOME-}/.m2/extensions.xml" ]] || echo "WARNING: ${HOME-}/.m2/extensions.xml exists, and Maven loads its core extensions (they can skip tests)."
# .mvn/ files Maven reads that git ignores, as in gate.sh; a failing listing
# says nothing, the gate runs anyway.
ignored_mvn || mvn_ignored=""
[[ -z "$mvn_ignored" ]] || echo "WARNING: git ignores .mvn/ files Maven reads: ${mvn_ignored//$'\n'/, } (they can skip tests)."

echo "pre-push: make lint-repo test (skip once with 'git push --no-verify')"
# A push from inside a make recipe hands that make's flags down in MAKEFLAGS;
# GNU make 4 also reads them from GNUMAKEFLAGS.
unset ONLY MAKEFLAGS MFLAGS GNUMAKEFLAGS MAKELEVEL MAKEFILES
# stdin carried git's ref lines, read above; /dev/null keeps a child that
# reads stdin from waiting on the terminal.
exec make --no-print-directory lint-repo test < /dev/null
