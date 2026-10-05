#!/usr/bin/env bash
# Tests for scripts/check_decisions.py through scripts/decisions.sh: per case, a
# fresh temp git repository whose docs/decisions.md is the case's heredoc. No
# network. Prints PASS/FAIL per case.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# shellcheck disable=SC2046 # one argument per variable name
unset $(git rev-parse --local-env-vars)
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 # no signing, no hooks from the user
export GIT_AUTHOR_NAME=devkit GIT_AUTHOR_EMAIL=devkit@example.invalid
export GIT_COMMITTER_NAME=devkit GIT_COMMITTER_EMAIL=devkit@example.invalid
real_git=$(command -v git)
repo=$work/repo
log=$work/git.log
fails=0

# decisions [TAG...]: a fresh repo whose docs/decisions.md is stdin, tagged TAG...
decisions() {
  rm -rf "$repo" "$log"
  git init -q -b main "$repo"
  mkdir -p "$repo/docs"
  cat >"$repo/docs/decisions.md"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m case
  local tag
  for tag in "$@"; do git -C "$repo" tag "$tag"; done
}

# A git for PATH that logs each call's argv to $log as one line, then runs the
# real git; with FAKE_GIT_FAIL=1 a for-each-ref fails instead.
mkdir "$work/bin"
cat >"$work/bin/git" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >>"$log"
[[ \${FAKE_GIT_FAIL:-0} == 0 || \$1 != for-each-ref ]] || { echo "fatal: no refs here" >&2; exit 128; }
exec "$real_git" "\$@"
EOF
chmod +x "$work/bin/git"

# expect LABEL WANT-STATUS WANT-TEXT...: run the check on the repo; the
# output must contain every WANT-TEXT and no Python traceback
expect() {
  local label=$1 want=$2 out rc=0 ok=true text
  shift 2
  out=$(PROJECT_ROOT=$repo DEVKIT=$root "$root/scripts/decisions.sh" 2>&1) || rc=$?
  for text in "$@"; do [[ $out == *"$text"* ]] || ok=false; done
  if [[ $rc == "$want" && $ok == true && $out != *Traceback* ]]; then
    echo "PASS $label"
  else
    echo "FAIL $label: exit $rc, want $want and each of [$*] in:"
    printf '%s\n' "$out"
    fails=$((fails + 1))
  fi
}

# fact LABEL COMMAND...: COMMAND must succeed
fact() {
  if "${@:2}"; then echo "PASS $1"; else
    echo "FAIL $1"
    fails=$((fails + 1))
  fi
}

at=docs/decisions.md

# The project keeps no log, or one that cannot be read.
rm -rf "$repo" && git init -q -b main "$repo"
expect "a project without docs/decisions.md is skipped" 0 "lint-decisions: no docs/decisions.md; skipped."
printf '\xff\n' | decisions
expect "a log that is not UTF-8 fails" 1 "ERROR: cannot read docs/decisions.md: not UTF-8"

# Premise and guard.
decisions <<'EOF'
## ADR-1 A preference

**Status:** Accepted

**Decision:** pick one.
EOF
expect "an entry without a premise needs no guard" 0 "decisions log: 1 entry; premise guards: 0 active"
decisions <<'EOF'
## ADR-1 Watched

**Status:** Accepted

**Premise:** p
**Guard:** watcher, a check.
EOF
expect "a watcher guard needs no trigger" 0 "1 active (1 watcher, 0 cascade, 0 memory-only)"
decisions <<'EOF'
## ADR-1 Unguarded

**Status:** Accepted

**Premise:** p

**See:** y
EOF
expect "a premise without a guard fails" 1 "$at:5: ADR-1 has a '**Premise:**' but no '**Guard:**' line"
decisions <<'EOF'
## ADR-1 Remembered

**Status:** Accepted

**Premise:** p
**Guard:** memory-only, why
EOF
expect "a memory-only guard passes" 0 "(0 watcher, 0 cascade, 1 memory-only)"
decisions <<'EOF'
## ADR-1 Hoped

**Status:** Accepted

**Premise:** p
**Guard:** wishful, why
EOF
expect "a guard of another class fails" 1 "$at:6: ADR-1's '**Guard:**' starts with 'wishful' where one of"
decisions <<'EOF'
## ADR-1 Cascading

**Status:** Accepted

**Premise:** p
**Guard:** cascade, why
EOF
expect "a cascade guard without a trigger fails" 1 "$at:6: ADR-1's cascade guard names no 'trigger: tag:<tag>' (found none)"
decisions <<'EOF'
## ADR-1 Cascading

**Status:** Accepted

**Premise:** p
**Guard:** cascade, why; trigger: vibes:shipped
EOF
expect "a cascade trigger that is not a tag fails" 1 "names no 'trigger: tag:<tag>' (found 'vibes:shipped')"
decisions <<'EOF'
## ADR-1 Cascading

**Status:** Accepted

**Premise:** p
**Guard:** cascade, why; trigger: tag:9.9.9
EOF
expect "a cascade whose tag does not exist passes" 0 "1 active (0 watcher, 1 cascade, 0 memory-only)"
decisions 9.9.9 <<'EOF'
## ADR-1 Cascading

**Status:** Accepted

**Premise:** p
**Guard:** cascade, why; trigger: tag:9.9.9.
EOF
expect "an active cascade whose tag exists fails as spent" 1 "$at:6: ADR-1 is spent: its trigger 'tag:9.9.9' exists"
decisions 9.9.9 <<'EOF'
## Superseded

## ADR-9 Cascaded

**Status:** spent at 9.9.9

**Premise:** p
**Guard:** cascade, why; trigger: tag:9.9.9
EOF
expect "the same entry under '## Superseded' passes" 0 "0 active (0 watcher, 0 cascade, 0 memory-only), 1 retired"
decisions 2.0.0 <<'EOF'
## ADR-1 Cascading

**Status:** Accepted

**Premise:** p

**Guard:** cascade, the premise dies at a loud event;
trigger: tag:2.0.0 and then it is spent.
EOF
expect "a trigger wrapped onto the guard paragraph's next line is read" 1 "$at:7: ADR-1 is spent"
decisions 1.0 <<'EOF'
## ADR-1 Cascading

**Status:** Accepted

**Premise:** p
**Guard:** cascade, why; trigger: tag:1.*
EOF
expect "a trigger is a tag name, not a pattern" 0 "1 cascade"

# Status markers.
decisions <<'EOF'
## ADR-1 One marker

**Date:** d · **Status:** Accepted

**Decision:** d.
EOF
expect "one status marker passes" 0 "decisions log: 1 entry;"
decisions <<'EOF'
## ADR-1 Drifted

**Date:** d · **Status**: Accepted
EOF
expect "a drifted marker fails" 1 "$at:1: ADR-1 carries 0 '**Status:** ' markers where exactly one is required"
decisions <<'EOF'
## ADR-1 Doubled

**Status:** Accepted

**Status:** Proposed
EOF
expect "a doubled marker fails" 1 "$at:1: ADR-1 carries 2 '**Status:** ' markers"
decisions <<'EOF'
Preamble mentioning **Status:** twice: **Status:** here.

## ADR-1 After a preamble

**Date:** d · **Status:** Proposed
EOF
expect "markers outside any entry are not counted" 0 "decisions log: 1 entry;"
decisions <<'EOF'
## ADR-1 Miscased

**Date:** d · **Status:** accepted
EOF
expect "a miscased status fails" 1 "$at:3: ADR-1 has the status 'accepted'"
decisions <<'EOF'
## ADR-1 Drafted

**Date:** d · **Status:** Draft
EOF
expect "a status outside the vocabulary fails" 1 "$at:3: ADR-1 has the status 'Draft'"
decisions <<'EOF'
## ADR-1 Kept

**Date:** d · **Status:** Accepted

## superseded

## ADR-2 Replaced

**Date:** d · **Status:** superseded by ADR-1
EOF
expect "a retired entry's status is free text" 0 "decisions log: 2 entries;"
decisions <<'EOF'
## ADR-1 Sectioned

**Status:** Accepted

## Notes

**Status:** Draft
EOF
expect "an entry ends at the next '## ' heading" 0 "decisions log: 1 entry;"

# Fenced code blocks, and headings that name an ADR.
decisions 9.9.9 <<'EOF'
## ADR-1 Quoting a heading

**Status:** Accepted

```
## Superseded
```

## ADR-2 Cascading

**Status:** Accepted

**Premise:** p
**Guard:** cascade, why; trigger: tag:9.9.9
EOF
expect "a fenced '## Superseded' retires nothing" 1 "$at:14: ADR-2 is spent" "2 entries; premise guards: 1 active"
decisions <<'EOF'
## ADR-1 Quoting an entry

**Status:** Accepted

~~~markdown
## ADR-9 Example
**Status:** Draft
~~~
EOF
expect "a fenced '## ADR-9' is no entry" 0 "decisions log: 1 entry;"
decisions <<'EOF'
## ADR-1 Quoting a comment

**Status:** Accepted

```sh
## comment
```

**Premise:** p
EOF
expect "a fenced '## comment' does not end the entry" 1 "$at:9: ADR-1 has a '**Premise:**' but no '**Guard:**' line"
decisions <<'EOF'
## ADR-1 Quoting a marker

**Status:** Accepted

````
**Status:** Draft
```
**Premise:** p
````
EOF
expect "fenced labels are not read, up to a fence as long as the opener" 0 "decisions log: 1 entry;"
decisions <<'EOF'
## ADR-1 Quoting

**Status:** Accepted

```
## ADR-2 Hidden

**Status:** Draft
EOF
expect "a fence that never closes fails" 1 \
  "$at:5: a code fence opened here never closes, so every entry after it goes unchecked" "decisions log: 1 entry;"
decisions 9.9.9 <<'EOF'
## ADR-1 Cascading

**Status:** Accepted

**Premise:** p
**Guard:** cascade, why
```
trigger: tag:9.9.9
```
EOF
expect "a guard paragraph ends at a fence" 1 "$at:6: ADR-1's cascade guard names no 'trigger: tag:<tag>' (found none)"
decisions <<'EOF'
## ADR-1 Kept

**Status:** Accepted

##  ADR-2 Two spaces

### ADR-3 Too deep

## ADR-4a Suffixed
EOF
expect "a heading naming an ADR that is no entry heading fails" 1 \
  "$at:5: '##  ADR-2 Two spaces' is not an entry heading: use '## ADR-<digits>'" \
  "$at:7: '### ADR-3 Too deep' is not an entry heading" "$at:9: '## ADR-4a Suffixed' is not an entry heading"

# Backticks around a trigger.
decisions 9.9.9 <<'EOF'
## ADR-1 Cascading

**Status:** Accepted

**Premise:** p
**Guard:** cascade, why; `trigger: tag:9.9.9`.
EOF
expect "a trigger in inline code is read without its backticks" 1 "$at:6: ADR-1 is spent: its trigger 'tag:9.9.9' exists"
decisions <<'EOF'
## ADR-1 Cascading

**Status:** Accepted

**Premise:** p
**Guard:** cascade, why; trigger: tag:9.9.9`x`
EOF
expect "a trigger still holding a backtick fails" 1 "$at:6: ADR-1's trigger 'tag:9.9.9\`x' holds a backtick"

# Repeated labels.
decisions <<'EOF'
## ADR-1 Two premises

**Status:** Accepted

**Premise:** p
**Premise:** p2
**Guard:** watcher, a check.
EOF
expect "a second premise line fails" 1 "$at:1: ADR-1 has 2 lines starting with '**Premise:**'"
decisions <<'EOF'
## ADR-1 Two guards

**Status:** Accepted

**Premise:** p
**Guard:** watcher, a check.
**Guard:** memory-only, why
EOF
expect "a second guard line fails" 1 "$at:1: ADR-1 has 2 lines starting with '**Guard:**'"
decisions <<'EOF'
## ADR-1 Quoted

**Status:** Accepted

**Premise:** p
**Guard:** watcher, a check.

- **Guard:** is unchanged; still watcher.
EOF
expect "a label quoted after '- ' is not read" 0 "1 watcher"

# Git: what it is asked, and when it cannot answer.
decisions <<'EOF'
## ADR-1 Watched

**Status:** Accepted

**Premise:** p
**Guard:** watcher, a check.
EOF
PATH=$work/bin:$PATH expect "a log without triggers passes" 0 "1 watcher"
fact "a log without triggers makes no git call" test ! -e "$log"
decisions 9.9.9 <<'EOF'
## ADR-1 Odd trigger

**Status:** Accepted

**Premise:** p
**Guard:** cascade, why; trigger: tag:-d
EOF
PATH=$work/bin:$PATH expect "a trigger shaped like an option is only compared" 0 "1 cascade"
fact "the log's text never reaches git's command line" diff - "$log" <<'EOF'
rev-parse --is-shallow-repository
for-each-ref --format=%(refname:strip=2) refs/tags
EOF
FAKE_GIT_FAIL=1 PATH=$work/bin:$PATH expect "a failed tag listing fails" 1 \
  "ERROR: git cannot read the tags in $repo: fatal: no refs here"
mkdir "$work/plain" "$work/plain/docs"
cp "$repo/docs/decisions.md" "$work/plain/docs/"
GIT_CEILING_DIRECTORIES=$work repo=$work/plain expect "a directory outside a git work tree fails" 1 \
  "ERROR: git cannot read the tags in $work/plain"
# shallow: a --depth 1 clone of the repo, with a second commit so it is cut short
shallow() {
  git -C "$repo" commit -q --allow-empty -m second
  rm -rf "$work/shallow"
  git clone -q --depth 1 "file://$repo" "$work/shallow"
}
shallow
repo=$work/shallow expect "a shallow clone with an active cascade's trigger fails" 1 \
  "ERROR: $work/shallow is a shallow clone, whose tags are incomplete"
decisions <<'EOF'
## ADR-1 Watched

**Status:** Accepted

**Premise:** p
**Guard:** watcher; trigger: tag:9.9.9

## Superseded

## ADR-2 Cascaded

**Status:** spent

**Premise:** p
**Guard:** cascade, why; trigger: tag:9.9.9
EOF
shallow
repo=$work/shallow PATH=$work/bin:$PATH expect "a shallow clone whose triggers are all retired or not cascades passes" 0 \
  "1 active (1 watcher, 0 cascade, 0 memory-only), 1 retired"
fact "triggers that cannot make an entry spent make no git call" test ! -e "$log"

# The census.
decisions <<'EOF'
# Decisions

## ADR-1 A preference

**Status:** Accepted

## ADR-2 Watched

**Status:** Accepted

**Premise:** p
**Guard:** watcher

## ADR-3 Cascading

**Status:** Proposed

**Premise:** p
**Guard:** cascade; trigger: tag:5.0.0

## ADR-4 Remembered

**Status:** Accepted

**Premise:** p
**Guard:** memory-only

## Superseded

## ADR-5 Retired

**Status:** replaced by ADR-2

**Premise:** p
**Guard:** watcher
EOF
expect "the census counts the entries and the guards by class" 0 \
  "decisions log: 5 entries; premise guards: 3 active (1 watcher, 1 cascade, 1 memory-only), 1 retired"

[[ $fails == 0 ]]
