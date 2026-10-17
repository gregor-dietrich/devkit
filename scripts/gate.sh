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
#   - git ignores none of the files pytest reads (its configuration, coverage's
#     and every conftest.py outside the directories it skips);
#   - no POM profile has an <activation> on an environment variable or a file,
#     and no POM is one git ignores, that could differ from a fresh checkout of
#     HEAD;
#   - no environment variable, mavenrc file, user-level core extensions file or
#     settings.xml profile property that can skip or deselect tests or skew
#     coverage is set.
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
    files=$(GIT_LITERAL_PATHSPECS=0 git ls-files -v -- :/ 2> /dev/null) || return 1
    ! grep -q '^[a-zS]' <<< "$files"
}

# ignored_mvn: sets mvn_ignored to the ignored ones (a line each) among the three
# files under .mvn/ Maven reads whether git tracks them or not (not
# .mvn/wrapper/), which strictly_clean counts as clean. Fails when git does.
# Duplicated in scripts/hooks/pre-push.sh, which only warns.
ignored_mvn() {
    mvn_ignored=$(git ls-files --others --ignored --exclude-standard -- .mvn/maven.config .mvn/extensions.xml .mvn/jvm.config 2> /dev/null)
}

# ignored_pytest: sets pytest_ignored to the ignored ones (a line each, in git's
# order) among the files pytest reads whether git tracks them or not, which
# strictly_clean counts as clean: in a project with a tracked root pyproject.toml,
# its configuration files and coverage's .coveragerc in each directory holding a
# tracked pyproject.toml (a member) and each directory above it up to the top
# level, and every conftest.py except one below a directory pytest does not
# enter inside its member: a default norecursedirs one (.*, venv, build, dist,
# node_modules, *.egg, _darcs, CVS, {arch}) or a virtual environment (a regular
# file pyvenv.cfg or conda-meta/history in it). A member's test*/conftest.py
# always counts: pytest loads it at startup. The project's
# own norecursedirs, testpaths and collect_ignore are not read. A listed
# directory (a trailing slash) is a nested repository, which git does not
# enter: it is dropped. GIT_LITERAL_PATHSPECS=0, since pathspec magic is
# needed. Fails when git does. Accepted misses are tracked in #157.
# Duplicated in scripts/hooks/pre-push.sh, which only warns.
ignored_pytest() {
    local dir file path failed rel acc comp seen=$'\n' members=$'\n' found
    local specs=(':(glob)**/conftest.py')
    pytest_ignored=""
    failed=""
    while IFS= read -r -d '' path || { failed=$path; false; }; do
        dir=${path%pyproject.toml}
        members="$members/$dir"$'\n'
        while [[ "$seen" != *$'\n'"/$dir"$'\n'* ]]; do
            seen="$seen/$dir"$'\n'
            for file in pytest.toml .pytest.toml pytest.ini .pytest.ini pyproject.toml tox.ini setup.cfg .coveragerc; do
                specs+=(":(literal)$dir$file")
            done
            [[ -n "$dir" ]] || break
            dir=${dir%/}
            if [[ "$dir" == */* ]]; then dir=${dir%/*}/; else dir=""; fi
        done
    done < <(GIT_LITERAL_PATHSPECS=0 git -c core.quotePath=false ls-files -z -- ':(glob)**/pyproject.toml' 2> /dev/null || printf x)
    [[ -z "$failed" ]] || return 1
    [[ "$members" == *$'\n/\n'* ]] || return 0
    found=$(GIT_LITERAL_PATHSPECS=0 git -c core.quotePath=false ls-files --others --ignored --exclude-standard -- "${specs[@]}" 2> /dev/null) || return 1
    while IFS= read -r path; do
        [[ -n "$path" && "$path" != */ ]] || continue
        if [[ "$path" == */conftest.py ]]; then
            dir=${path%/*}/
            while [[ "$members" != *$'\n'"/$dir"$'\n'* ]]; do
                dir=${dir%/}
                if [[ "$dir" == */* ]]; then dir=${dir%/*}/; else dir=""; fi
            done
            rel=${path#"$dir"}
            acc=$dir
            [[ "$rel" == test*/conftest.py && "$rel" != */*/* ]] || while [[ "$rel" == */* ]]; do
                comp=${rel%%/*}
                rel=${rel#*/}
                acc="$acc$comp/"
                case "$comp" in
                    .* | venv | build | dist | node_modules | *.egg | _darcs | CVS | '{arch}') continue 2 ;;
                esac
                [[ ! -f "${acc}pyvenv.cfg" && ! -f "${acc}conda-meta/history" ]] || continue 2
            done
        fi
        pytest_ignored="${pytest_ignored:+$pytest_ignored$'\n'}$path"
    done <<< "$found"
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

# identifier NAME: NAME is a shell identifier. Explicit character lists, so the
# locale cannot widen a range. Duplicated in scripts/hooks/pre-push.sh.
identifier() {
    [[ -n "$1" && "$1" != *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_]* && "$1" != [0123456789]* ]]
}

# xml_texts TEXT TAG: the trimmed, non-empty text of each <TAG> element in TEXT,
# a line each. Duplicated in scripts/hooks/pre-push.sh.
xml_texts() {
    local rest=$1 t
    while [[ "$rest" == *"<$2>"* ]]; do
        rest=${rest#*"<$2>"}
        t=$(trim "${rest%%"</$2>"*}")
        [[ -z "$t" ]] || printf '%s\n' "$t"
    done
}

# normalize_tags TEXT: TEXT with the tags the POM scan reads written plainly:
# <TAG attr="1"> and <TAG > become <TAG> (<TAG/> when the span ends in a slash)
# and </TAG > becomes </TAG>, for the tags listed below only (<names> is not
# <name>). An attribute value holding > ends the tag early: an accepted miss
# (#150). Pure parameter expansion, for bash 3.2.
# Duplicated in scripts/hooks/pre-push.sh.
normalize_tags() {
    local rest=$1 out="" after tail tag
    while [[ "$rest" == *'<'* ]]; do
        out="$out${rest%%'<'*}<"
        rest=${rest#*'<'}
        after=${rest#/}
        for tag in activation name value exists missing file property profiles module modules parent relativePath; do
            [[ "$after" == "$tag"[[:space:]/]* ]] || continue
            tail=${after#"$tag"}
            if [[ "$rest" == /* ]]; then
                tail=${tail#"${tail%%[![:space:]]*}"}
                [[ "$tail" == '>'* ]] || break
                out="$out/$tag>"
            else
                [[ "$tail" == *'>'* ]] || break
                if [[ "${tail%%'>'*}" == */ ]]; then out="$out$tag/>"; else out="$out$tag>"; fi
            fi
            rest=${tail#*'>'}
            break
        done
    done
    printf '%s' "$out$rest"
}

# note_ambient LINE: adds LINE to pom_ambient unless it is there; text from a
# POM reaches the terminal with its control characters replaced.
# Duplicated in scripts/hooks/pre-push.sh.
note_ambient() {
    local line=${1//[[:cntrl:]]/?}
    [[ $'\n'"$pom_ambient"$'\n' == *$'\n'"$line"$'\n'* ]] || pom_ambient="${pom_ambient:+$pom_ambient$'\n'}$line"
}

# read_pom POM: sets pom_content to the text of POM that the scan parses
# (comments stripped, tags normalized), and notes a processing instruction:
# strip_comments would read `<?x <!-- ?>` as an unterminated comment and drop
# the rest, so any <? but a leading XML declaration counts. Fails when POM
# cannot be read.
# Duplicated in scripts/hooks/pre-push.sh.
read_pom() {
    local raw lead
    raw=$(<"$1") || return 1
    lead=${raw#$'\xEF\xBB\xBF'}
    lead=${lead#"${lead%%[![:space:]]*}"}
    if [[ "$lead" == '<?xml'[[:space:]]* && "$lead" == *'?>'* ]]; then lead=${lead#*'?>'}; fi
    if [[ "$lead" == *'<?'* ]]; then note_ambient "$1: holds a processing instruction"; fi
    pom_content=$(strip_comments "$raw")
    pom_content=$(normalize_tags "$pom_content")
}

# ambient_file TOP PATH: 0 when PATH exists and either lies outside the top
# level TOP (the current directory, which is the git top level) or git tracks
# nothing at it (untracked or ignored; a directory holding a tracked file is
# tracked); 1 when it does not count (it does not exist, or is TOP's .git or
# lies below it, which every checkout has); 2 when git fails. The directory is
# resolved physically, so `..` is honoured; `*` and `?` are literal, as in
# Maven. 0 also when the directory cannot be entered: a path the scan cannot
# resolve counts.
# Duplicated in scripts/hooks/pre-push.sh.
ambient_file() {
    local full dir
    [[ -e "$2" ]] || return 1
    if [[ -d "$2" ]]; then
        full=$(cd "$2" 2> /dev/null && pwd -P) || return 0
    else
        dir=${2%/*}
        [[ "$2" == */* ]] || dir=.
        [[ -n "$dir" ]] || dir=/
        full=$(cd "$dir" 2> /dev/null && pwd -P) || return 0
        full=${full%/}/${2##*/}
    fi
    if [[ "$full" != "$1"/* && "$full" != "$1" ]]; then return 0; fi
    full=${full#"$1"}
    full=${full#/}
    [[ -n "$full" ]] || full=.
    if [[ "$full" == .git || "$full" == .git/* ]]; then return 1; fi
    full=$(GIT_LITERAL_PATHSPECS=0 git ls-files -- ":(literal)$full" 2> /dev/null) || return 2
    [[ -z "$full" ]]
}

# candidate_ambient TOP PATH: ambient_file, asked once per PATH in a scan (the
# answers are kept in pom_file_yes and pom_file_no, which ambient_profiles
# resets).
# Duplicated in scripts/hooks/pre-push.sh.
candidate_ambient() {
    local status=0
    if [[ "$pom_file_yes" == *$'\n'"$2"$'\n'* ]]; then return 0; fi
    if [[ "$pom_file_no" == *$'\n'"$2"$'\n'* ]]; then return 1; fi
    ambient_file "$1" "$2" || status=$?
    case "$status" in
        0) pom_file_yes="$pom_file_yes$2"$'\n' ;;
        1) pom_file_no="$pom_file_no$2"$'\n' ;;
    esac
    return "$status"
}

# resolve_pom TOP DIR TARGET: sets pom_resolved to the POM that TARGET (a file,
# or a directory holding a pom.xml) names from DIR, as a path relative to the
# top level TOP. 0 when it exists inside TOP; 1 when it does not exist; 2 when
# it lies outside TOP; 3 when its directory cannot be entered.
# Duplicated in scripts/hooks/pre-push.sh.
resolve_pom() {
    local file=$2/$3 resolved
    [[ -f "$file" ]] || file=$file/pom.xml
    [[ -f "$file" ]] || return 1
    resolved=$(cd "${file%/*}" 2> /dev/null && pwd -P) || return 3
    if [[ "$resolved" == "$1" ]]; then
        pom_resolved=${file##*/}
    elif [[ "$resolved" == "$1"/* ]]; then
        pom_resolved=${resolved#"$1"/}/${file##*/}
    else
        return 2
    fi
}

# reactor_poms TOP: sets pom_list to the POMs in scope, a path a line, relative
# to the top level TOP (the current directory), without duplicates: ./pom.xml,
# every <module> (also inside <profiles>) and every <parent> <relativePath>
# (default ../pom.xml; an empty one names no POM), followed transitively, each
# a file or a directory holding a pom.xml, that exist. It notes (note_ambient)
# a POM git does not track, a <module> holding ${, and a <module> that resolves
# outside the top level. A module that does not exist is skipped silently
# (Maven fails the build), as is a parent outside the top level (the default
# ../pom.xml of a repository's own parent). No ./pom.xml: no POMs. Fails when a
# POM cannot be read or git fails.
# Duplicated in scripts/hooks/pre-push.sh.
# shellcheck disable=SC2016 # the ${ is the start of a literal Maven expression
reactor_poms() {
    local queue="pom.xml" seen=$'\n' pom dir modules parent targets target kind status
    pom_list=""
    [[ -f pom.xml ]] || return 0
    while [[ -n "$queue" ]]; do
        pom=${queue%%$'\n'*}
        if [[ "$queue" == *$'\n'* ]]; then queue=${queue#*$'\n'}; else queue=""; fi
        [[ "$seen" != *$'\n'"$pom"$'\n'* ]] || continue
        seen="$seen$pom"$'\n'
        pom_list="${pom_list:+$pom_list$'\n'}$pom"
        dir=${pom%/*}
        [[ "$pom" == */* ]] || dir=.
        status=0
        ambient_file "$1" "$pom" || status=$?
        [[ "$status" != 2 ]] || return 1
        [[ "$status" != 0 ]] || note_ambient "$pom: git does not track this POM"
        read_pom "$pom" || return 1
        targets=""
        modules=$(xml_texts "$pom_content" module)
        [[ -z "$modules" ]] || targets="m${modules//$'\n'/$'\nm'}"$'\n'
        parent=""
        if [[ "$pom_content" == *'<parent>'* ]]; then
            parent=${pom_content#*'<parent>'}
            parent=${parent%%'</parent>'*}
            if [[ "$parent" == *'<relativePath>'* ]]; then
                parent=$(xml_texts "$parent" relativePath)
            elif [[ "$parent" == *'<relativePath/>'* ]]; then
                parent=""
            else
                parent=../pom.xml
            fi
        fi
        [[ -z "$parent" ]] || targets="$targets"p"${parent//$'\n'/$'\np'}"$'\n'
        while IFS= read -r target; do
            [[ -n "$target" ]] || continue
            kind=${target:0:1}
            target=${target:1}
            if [[ "$kind" == m && "$target" == *'${'* ]]; then
                note_ambient "$pom: module $target holds a property"
                continue
            fi
            status=0
            resolve_pom "$1" "$dir" "$target" || status=$?
            case "$status" in
                0) queue="${queue:+$queue$'\n'}$pom_resolved" ;;
                2) [[ "$kind" == p ]] || note_ambient "$pom: module $target resolves outside the project" ;;
                3) return 1 ;;
            esac
        done <<< "$targets"
    done
}

# maven_config_file: .mvn/maven.config exists (tracked or not) and holds an
# option that names the POM to build (-f, --file, --file=PATH, -fPATH; not -fae,
# -ff or -fn), so Maven builds another root POM than the walk's ./pom.xml. A
# file that cannot be read counts.
# Duplicated in scripts/hooks/pre-push.sh.
maven_config_file() {
    local content rest word
    [[ -e .mvn/maven.config ]] || return 1
    content=$(<.mvn/maven.config) || return 0
    rest=$content
    while [[ -n "${rest//[[:space:]]/}" ]]; do
        rest=${rest#"${rest%%[![:space:]]*}"}
        word=${rest%%[[:space:]]*}
        rest=${rest#"$word"}
        case "$word" in
            -fae | -ff | -fn) ;;
            -f* | --file | --file=*) return 0 ;;
        esac
    done
    return 1
}

# collect_env KIND NAME POM: adds an environment check to pom_envchecks, a
# line each, for env_hits to run once ambient_profiles has returned.
# Duplicated in scripts/hooks/pre-push.sh.
collect_env() {
    pom_envchecks="${pom_envchecks:+$pom_envchecks$'\n'}$1 $2 $3"
}

# check_path TOP DIRS POM PATH: notes what the <exists> or <missing> PATH of POM
# depends on: a ${env.N} reference (collected, for env_hits), another ${...}
# property (model, -D or unknown), a form the scan does not resolve (a
# backslash, a .. component or a trailing slash, which Maven converts or
# normalises), or a file that exists without git tracking it. A relative path is
# tried in every directory of the newline-separated DIRS, as are ${basedir},
# ${project.basedir} and ${project.rootDirectory} (a superset of the projects
# Maven evaluates them for); an absolute one is tried once. An env reference
# leaves the other checks running on the rest of the path, and stays literal in
# the existence check, as Maven leaves an unset one. Fails when git does.
# Duplicated in scripts/hooks/pre-push.sh.
# shellcheck disable=SC2016 # the ${...} are literal Maven expressions
check_path() {
    local path=$4 rest bare name plain candidate dir status once=0 list=$2
    local rd='${project.rootDirectory}' uh='${user.home}' bd='${basedir}' pb='${project.basedir}'
    bare="" rest=$path
    while [[ "$rest" == *'${env.'* ]]; do
        bare=$bare${rest%%'${env.'*}
        rest=${rest#*'${env.'}
        name=${rest%%'}'*}
        if identifier "$name"; then collect_env set "$name" "$3"; else note_ambient "$3: env.$name is not a variable name the scan can check"; fi
        if [[ "$rest" == *'}'* ]]; then rest=${rest#*'}'}; else rest=""; fi
    done
    bare=${bare}${rest}
    plain=${bare//"$uh"/"${HOME-}"}
    plain=${plain//"$bd"/}
    plain=${plain//"$pb"/}
    plain=${plain//"$rd"/}
    if [[ "$plain" == *'${'* ]]; then
        note_ambient "$3: $path depends on a property"
        return 0
    fi
    if [[ "$plain" == *$'\\'* || "$plain" == .. || "$plain" == ../* || "$plain" == */.. || "$plain" == */../* || "$plain" == */ ]]; then
        note_ambient "$3: $path is a path the scan does not resolve"
        return 0
    fi
    path=${path//"$uh"/"${HOME-}"}
    if [[ "$path" != *"$bd"* && "$path" != *"$pb"* && "$path" != *"$rd"* && "$path" == /* ]]; then
        once=1 list=.
    fi
    while IFS= read -r dir; do
        [[ -n "$dir" ]] || continue
        if [[ "$once" == 1 ]]; then
            candidate=$path
        elif [[ "$path" == *"$bd"* || "$path" == *"$pb"* || "$path" == *"$rd"* ]]; then
            candidate=${path//"$bd"/"$1/$dir"}
            candidate=${candidate//"$pb"/"$1/$dir"}
            candidate=${candidate//"$rd"/"$1/$dir"}
        else
            candidate=$dir/$path
        fi
        status=0
        candidate_ambient "$1" "$candidate" || status=$?
        [[ "$status" != 2 ]] || return 1
        if [[ "$status" == 0 ]]; then
            note_ambient "$3: $4 exists and git does not track it"
            return 0
        fi
    done <<< "$list"
}

# check_activation TOP DIRS POM ACTIVATION: notes what the text of one
# <activation> of POM depends on: a <name> of env.N or !env.N (collected, for
# env_hits), a <name> or <value> holding ${ (Maven interpolates both), and its
# <exists> and <missing> paths (check_path; both are checked, though Maven
# ignores <missing> next to <exists>). A name that is no variable name counts
# at once. Fails when check_path does.
# Duplicated in scripts/hooks/pre-push.sh.
# shellcheck disable=SC2016 # the ${ is the start of a literal Maven expression
check_activation() {
    local text name tag
    while IFS= read -r text; do
        [[ -n "$text" ]] || continue
        if [[ "$text" == *'${'* ]]; then
            note_ambient "$3: $text in an activation depends on a property"
            continue
        fi
        name=${text#!}
        [[ "$name" == env.* ]] || continue
        name=${name#env.}
        if identifier "$name"; then collect_env nonempty "$name" "$3"; else note_ambient "$3: env.$name is not a variable name the scan can check"; fi
    done <<< "$(xml_texts "$4" name)"
    while IFS= read -r text; do
        [[ "$text" != *'${'* ]] || note_ambient "$3: $text in an activation depends on a property"
    done <<< "$(xml_texts "$4" value)"
    for tag in exists missing; do
        while IFS= read -r text; do
            [[ -z "$text" ]] || check_path "$1" "$2" "$3" "$text" || return 1
        done <<< "$(xml_texts "$4" "$tag")"
    done
}

# ambient_profiles: sets pom_ambient to a line for each way the project's POMs
# could differ from a fresh checkout of HEAD in a clean environment (what makes
# tests run or not is Maven's, and a profile can skip them): a POM git does not
# track (reactor_poms), a <module> holding ${ or resolving outside the top
# level, a processing instruction, a .mvn/maven.config naming the POM to build,
# and in each <activation> a <name> or <value> holding ${, a <name> of env.N or
# !env.N, an <exists> or <missing> path that names ${env.N}, that depends on
# another ${...} property (model, -D or unknown), that is a form the scan does
# not resolve (a backslash, a .. component, a trailing slash), or that exists
# without git tracking it. A relative path, ${basedir} or
# ${project.rootDirectory} is tried in the directory of every in-scope POM, a
# superset of the projects Maven evaluates it for. Lines name the POM and the
# name or path as written, never a value. The environment checks are only
# collected here, in pom_envchecks: env_hits runs them (see there). Fails when
# reactor_poms or git does. Accepted misses, which only a deliberate setup
# reaches and which are tracked in #150: a symlink in either direction (a
# tracked link to an ignored file, an ignored link to a tracked directory or a
# path through one), XML entities and CDATA, an attribute value holding >, a
# POM reached only through a parent outside the top level, a variable whose
# value is only newlines, a crafted CDPATH, a non-UTF-8 POM naming a non-ASCII
# path, and a path with an internal newline. Exported make variables
# (PROJECT_ROOT, DEVKIT, HOME ...) over-count a profile named after them.
# Duplicated in scripts/hooks/pre-push.sh.
ambient_profiles() {
    local top dirs pom dir activation
    pom_ambient="" pom_envchecks="" pom_file_yes=$'\n' pom_file_no=$'\n'
    if maven_config_file; then note_ambient ".mvn/maven.config names the POM to build"; fi
    top=$(pwd -P) || return 1
    reactor_poms "$top" || return 1
    [[ -n "$pom_list" ]] || return 0
    dirs=""
    while IFS= read -r pom; do
        dir=${pom%/*}
        [[ "$pom" == */* ]] || dir=.
        dirs="$dirs$dir"$'\n'
    done <<< "$pom_list"
    while IFS= read -r pom; do
        read_pom "$pom" || return 1
        activation=$pom_content
        while [[ "$activation" == *'<activation>'* ]]; do
            activation=${activation#*'<activation>'}
            check_activation "$top" "$dirs" "$pom" "${activation%%'</activation>'*}" || return 1
        done
    done <<< "$pom_list"
}

# env_hits: notes each environment check ambient_profiles collected: a `set`
# one counts when the variable is set, empty or not (Maven substitutes an empty
# ${env.N}), a `nonempty` one when it is set and not empty (the property
# activation treats an empty value as unset). printenv shows what Maven sees:
# the environment, not this script's own variables. It declares no locals, and
# nothing that does is on the stack (see pom_scan): a local shadows the
# exported variable of its name, while a script global of that name *is* that
# variable, so what printenv sees there is what make inherits.
# Duplicated in scripts/hooks/pre-push.sh.
env_hits() {
    while read -r pom_env_kind pom_env_name pom_env_pom; do
        [[ -n "$pom_env_kind" ]] || continue
        if [[ "$pom_env_kind" == set ]]; then
            printenv "$pom_env_name" > /dev/null || continue
        else
            [[ -n "$(printenv "$pom_env_name")" ]] || continue
        fi
        note_ambient "$pom_env_pom: the environment variable $pom_env_name is set"
    done <<< "$pom_envchecks"
}

# pom_scan: ambient_profiles, then env_hits once its locals are gone. Declares
# no locals either. Fails when ambient_profiles does.
# Duplicated in scripts/hooks/pre-push.sh.
pom_scan() {
    ambient_profiles && env_hits
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
    ignored_pytest || why "git could not list the ignored files pytest reads"
    [[ -z "$pytest_ignored" ]] || why "git ignores files pytest reads: ${pytest_ignored//$'\n'/, } (they can deselect tests or skew coverage)"
    pom_scan || why "could not scan the project's POMs"
    [[ -z "$pom_ambient" ]] || why "the project's POMs depend on ambient state: ${pom_ambient//$'\n'/, } (they can skip tests)"
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
[[ -z "${PYTEST_PLUGINS-}" ]] || why "PYTEST_PLUGINS is set (it can deselect tests)"
[[ -z "${COVERAGE_RCFILE-}" ]] || why "COVERAGE_RCFILE is set (it can skew coverage)"
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
    ignored_pytest || why "git could not list the ignored files pytest reads"
    [[ -z "$pytest_ignored" ]] || why "git ignores files pytest reads that appeared during the run: ${pytest_ignored//$'\n'/, } (they can deselect tests or skew coverage)"
    # The environment cannot change during the run, so a hit here is a file.
    pom_scan || why "could not scan the project's POMs"
    [[ -z "$pom_ambient" ]] || why "the project's POMs depend on ambient state that appeared during the run: ${pom_ambient//$'\n'/, } (they can skip tests)"
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
