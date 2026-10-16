#!/usr/bin/env bash
# Tests for scripts/python/anchored_match.py: a temp project, its own git
# repository, with devkit.toml written per case and Python files holding the
# flagged and the clean shapes. Needs python3 3.11 or later and git; no node
# and no network. Prints PASS/FAIL per case.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
# Physical: the scripts report resolved paths, and macOS's TMPDIR is under the
# /var -> /private/var symlink. Two steps, so set -e catches a failed mktemp.
work=$(mktemp -d)
work=$(cd "$work" && pwd -P)
trap 'rm -rf "$work"' EXIT
# shellcheck disable=SC2046 # one argument per variable name
unset $(git rev-parse --local-env-vars)
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 PYTHONDONTWRITEBYTECODE=1
export PROJECT_ROOT=$work/proj
proj=$PROJECT_ROOT fails=0

git init -q "$proj"
mkdir "$proj/src"

config() { printf '%s\n' "$@" >"$proj/devkit.toml"; } # config LINE...: devkit.toml holds the LINEs

# expect LABEL WANT-STATUS ARG... -- WANT-TEXT...: $driver ARGs end with
# WANT-STATUS, saying every WANT-TEXT, and no Python traceback.
driver=(python3 -I -S -B "$root/scripts/python/anchored_match.py")
expect() {
  local label=$1 want=$2 args=() out rc=0 text ok=true
  shift 2
  while [[ $1 != -- ]]; do args+=("$1") && shift; done
  shift
  out=$(cd "$work" && "${driver[@]}" "${args[@]}" 2>&1) || rc=$?
  for text in "$@"; do [[ $out == *"$text"* ]] || ok=false; done
  if [[ $rc == "$want" && $ok == true && $out != *Traceback* ]]; then
    echo "PASS $label"
  else
    echo "FAIL $label: exit $rc, want $want and each of [$*] in:"
    printf '%s\n' "$out"
    fails=$((fails + 1))
  fi
}

# absent LABEL TEXT...: run's output holds none of the TEXTs, and no traceback.
absent() {
  local label=$1 out rc=0 text ok=true
  shift
  out=$(cd "$work" && "${driver[@]}" run 2>&1) || rc=$?
  for text in "$@"; do [[ $out != *"$text"* ]] || ok=false; done
  if [[ $ok == true && $out != *Traceback* ]]; then
    echo "PASS $label"
  else
    echo "FAIL $label: none of [$*] wanted in:"
    printf '%s\n' "$out"
    fails=$((fails + 1))
  fi
}

table='[python.anchored-match]'
entry='[[python.anchored-match.accepted]]'
file='file = "src/flagged.py"'
fn='function = "plain"'
why='reason = "the caller strips the newline"'
version=$(python3 -c 'import platform; print(platform.python_version())')
exe=$(python3 -c 'import sys; print(sys.executable)')
excl='[[python.anchored-match.excluded]]'
remedy="fix the file so that the Python .python-version pins parses it, or exclude it with an $excl entry in devkit.toml (file and a reason)"

# Configuration.
config '[devkit]' 'version = "v0.0.0"'
expect "no table passes check-config" 0 check-config -- "[python.anchored-match]: 0 accepted entry(ies)"
config "$table"
expect "an empty table passes check-config" 0 check-config -- "0 accepted entry(ies)"
config '[python]'
expect "a python table without the table passes" 0 check-config -- "0 accepted entry(ies)"
rm "$proj/devkit.toml"
expect "no devkit.toml fails" 1 check-config -- "ERROR: no devkit.toml in $proj."
config 'python = 1'
expect "a python key that is no table counts as no table" 0 check-config -- "0 accepted entry(ies)"
config '[python]' 'anchored-match = 1'
expect "a table that is no table fails" 1 check-config -- "ERROR: [python.anchored-match] in devkit.toml must be a table"
config "$table" 'paths = ["src"]'
expect "an unknown table key fails" 1 check-config -- \
  "ERROR: [python.anchored-match] in devkit.toml sets unknown key(s) paths; it reads only accepted, excluded."
config "$table" 'accepted = "src/flagged.py"'
expect "accepted that is no array fails" 1 check-config -- "[[python.anchored-match.accepted]] in devkit.toml must be an array of tables"
config "$table" 'accepted = ["src/flagged.py"]'
expect "accepted that is an array of strings fails" 1 check-config -- "must be an array of tables, each with file, function and a reason."
config "$table" "$entry" "$file" "$fn"
expect "an entry without a reason fails" 1 check-config -- "entry 1 (src/flagged.py plain) needs a reason"
config "$table" "$entry" "$file" "$fn" 'reason = ""'
expect "an entry with an empty reason fails" 1 check-config -- "entry 1 (src/flagged.py plain) needs a reason"
config "$table" "$entry" "$file" "$fn" 'reason = " "'
expect "an entry with a blank reason fails" 1 check-config -- "entry 1 (src/flagged.py plain) needs a reason"
config "$table" "$entry" "$file" "$fn" "$why" 'reasons = "typo"'
expect "an unknown entry key fails" 1 check-config -- \
  "entry 1 sets unknown key(s) reasons; it reads only file, function and reason."
config "$table" "$entry" "$fn" "$why"
expect "an entry without a file fails" 1 check-config -- 'entry 1 needs file = "src/app/names.py".'
config "$table" "$entry" "$file" "$why"
expect "an entry without a function fails" 1 check-config -- 'entry 1 needs function = "check_name", or "<module>".'
config "$table" "$entry" 'file = ""' "$fn" "$why"
expect "an entry with an empty file fails" 1 check-config -- "entry 1 needs file ="
config "$table" "$entry" "$file" "$fn" "$why" "$entry" 'file = "./src/flagged.py"' "$fn" 'reason = "again"'
expect "a duplicate entry, however the file is spelled, fails" 1 check-config -- \
  "accepts src/flagged.py plain twice; remove one entry."
config "$table" "$entry" "$file" "$fn" "$why" "$entry" "$file" 'function = "other"' "$why"
expect "a valid config passes check-config" 0 check-config -- "[python.anchored-match]: 2 accepted entry(ies), 0 excluded file(s); the gate scans the 0 Python file(s)"

xfile='file = "src/x.py"'
xwhy='reason = "a py2 sample"'
config "$table" "$excl" "$xfile"
expect "an excluded entry without a reason fails" 1 check-config -- "$excl in devkit.toml entry 1 (src/x.py) needs a reason saying why the file is not scanned."
config "$table" "$excl" "$xfile" 'reason = " "'
expect "an excluded entry with a blank reason fails" 1 check-config -- "entry 1 (src/x.py) needs a reason"
config "$table" "$excl" 'file = " "' "$xwhy"
expect "an excluded entry with a blank file fails" 1 check-config -- "$excl in devkit.toml entry 1 needs file ="
config "$table" "$excl" "$xwhy"
expect "an excluded entry without a file fails" 1 check-config -- "entry 1 needs file ="
config "$table" "$excl" "$xfile" "$xwhy" 'function = "f"'
expect "an unknown excluded key fails" 1 check-config -- "entry 1 sets unknown key(s) function; it reads only file and reason."
config "$table" "$excl" "$xfile" "$xwhy" "$excl" 'file = "./src/x.py"' 'reason = "again"'
expect "a duplicate excluded file, however spelled, fails" 1 check-config -- "excludes src/x.py twice; remove one entry."
config "$table" 'excluded = "src/x.py"'
expect "excluded that is no array fails" 1 check-config -- "$excl in devkit.toml must be an array of tables, each with file and a reason."
config "$table" 'excluded = ["src/x.py"]'
expect "excluded that is an array of strings fails" 1 check-config -- "must be an array of tables, each with file and a reason."
config "$table" "$entry" 'file = "src/x.py"' "$fn" "$why" "$excl" "$xfile" "$xwhy"
expect "an accepted entry for an excluded file fails" 1 check-config -- "remove the accepted entry, an excluded file is not scanned."
printf 'x = 1\n' >"$proj/src/x.py"
printf 'y = 1\n' >"$proj/src/y.py"
config "$table" "$excl" "$xfile" "$xwhy"
expect "check-config counts the excluded file and drops it from the scanned count" 0 check-config -- \
  "0 accepted entry(ies), 1 excluded file(s); the gate scans the 1 Python file(s)"
rm "$proj/src/x.py" "$proj/src/y.py"

# Excluded files are neither parsed nor scanned; an entry git does not list is stale.
printf 'def broken(:\n' >"$proj/src/x.py"
config "$table" "$excl" "$xfile" "$xwhy"
expect "an excluded file that does not parse passes" 0 run -- "beyond the 0 accepted function(s)."
absent "an excluded file that does not parse is no parse error" "cannot parse"
printf 'import re\n\nre.match("^a$", "")\n' >"$proj/src/x.py"
expect "an excluded file holding a flagged call is not scanned" 0 run -- "beyond the 0 accepted function(s)."
config "$table" "$excl" 'file = "./src/x.py"' "$xwhy"
expect "an excluded ./src/x.py matches src/x.py" 0 run -- "beyond the 0 accepted function(s)."
config "$table"
expect "without the entry the same file is flagged" 1 run -- "src/x.py:3 in <module>"
config "$table" "$excl" 'file = "src/gone.py"' "$xwhy"
expect "a stale excluded entry fails, naming the file" 1 run -- \
  "ERROR: stale $excl entry, git lists no such Python file: src/gone.py" "remove the stale entries from devkit.toml."
config "$table" "$excl" 'file = "src"' "$xwhy"
expect "an excluded directory is stale: entries are files only" 1 run -- \
  "ERROR: stale $excl entry, git lists no such Python file: src"
rm "$proj/src/x.py"
config "$table"

# The flagged corpus: each shape at its exact line and qualname.
cat >"$proj/src/flagged.py" <<'EOF'
import re
import re as regex
from re import compile as comp
from re import match, search

CONST = r"^[a-z]+$"
UNANCHORED = r"^[a-z]+"
X = "x"
RX = re.compile(r"^b$")


def plain(s):
    re.match(r"^[a-z]+$", s)
    re.match(r"[a-z]+$", s)
    re.match(b"^a$", s)
    re.match(r"^a$", s, re.M)
    re.match("^a" "b$", s)
    re.match("a$|b", s)
    re.match(r"\\$", s)
    re.match(pattern="a$", string=s)
    re.match(CONST, s)
    re.match(UNANCHORED, s)
    local = re.compile("c$")
    local.match(s)
    re.compile(r"^d$").match(s)
    regex.match("e$", s)
    match("f$", s)
    comp("g$").match(s)
    re.match(rf"^{X}$", s)
    RX.match(s)
    re.search(r"^h$", s)
    re.search(r"\Ai$", s)
    search("^j$", s)


class Outer:
    def method(self):
        def inner():
            return re.match("k$", "")

        return inner


f = lambda s: re.match("l$", s)  # noqa: E731
re.match("m$", "")
EOF
config "$table"
want() { # want LINE QUALNAME PATTERN: the error line of the call at LINE, in the flagged file
  printf 'anchored .%s() not accepted in devkit.toml: src/flagged.py:%s in %s: %s' "${4:-match}" "$1" "$2" "$3"
}
expect "the flagged corpus fails at every shape's line and qualname" 1 run -- \
  "$(want 13 plain "'^[a-z]+\$'")" \
  "$(want 14 plain "'[a-z]+\$'")" \
  "$(want 15 plain "b'^a\$'")" \
  "$(want 16 plain "'^a\$'")" \
  "$(want 17 plain "'^ab\$'")" \
  "$(want 18 plain "'a\$|b'")" \
  "$(want 19 plain "'\\\\\\\\\$'")" \
  "$(want 20 plain "'a\$'")" \
  "$(want 21 plain "'^[a-z]+\$'")" \
  "$(want 24 plain "'c\$'")" \
  "$(want 25 plain "'^d\$'")" \
  "$(want 26 plain "'e\$'")" \
  "$(want 27 plain "'f\$'")" \
  "$(want 28 plain "'g\$'")" \
  "$(want 29 plain "'^{}\$'")" \
  "$(want 30 plain "'^b\$'")" \
  "$(want 31 plain "'^h\$'" search)" \
  "$(want 32 plain "'\\\\Ai\$'" search)" \
  "$(want 33 plain "'^j\$'" search)" \
  "$(want 39 Outer.method.inner "'k\$'")" \
  "$(want 44 '<lambda>' "'l\$'")" \
  "$(want 45 '<module>' "'m\$'")" \
  "To fix: use re.fullmatch (or \\A...\\Z), or accept the function with an [[python.anchored-match.accepted]] entry"
absent "the constant without a \$ at line 22 is not flagged" "src/flagged.py:22 "
config "$table" "$entry" "$file" "$fn" "$why" "$entry" "$file" 'function = "Outer.method.inner"' "$why" \
  "$entry" "$file" 'function = "<lambda>"' "$why" "$entry" "$file" 'function = "<module>"' "$why"
expect "every finding accepted by its function passes" 0 run -- "no anchored .match() or .search() beyond the 4 accepted function(s)."
rm "$proj/src/flagged.py"
config "$table"

# The escape and the class: \$ and [$] are no anchor, \\$ is one.
cat >"$proj/src/escapes.py" <<'EOF'
import re

re.match(r"^a\$", "")
re.match(r"^[$]", "")
re.match(r"^[^]$]", "")
re.match(r"^\\$", "")
re.match(r"^[\]$]", "")
re.match(r"^\\[$]", "")
EOF
expect "\\\$, [\$] and the class shapes are not flagged; \\\\\$ is" 1 run -- \
  "src/escapes.py:6 in <module>: '^\\\\\\\\\$'"
absent "\\\$, [\$], [^]\$] and [\\]\$] are not flagged, nor is a class after an escaped backslash" \
  "src/escapes.py:3 " "src/escapes.py:4 " "src/escapes.py:5 " "src/escapes.py:7 " "src/escapes.py:8 "
rm "$proj/src/escapes.py"

# A compiled name's pattern resolves where re.compile sits, not where .match is called.
cat >"$proj/src/scoped.py" <<'EOF'
import re

PAT = r"^a$"
RX = re.compile(PAT)


def check(PAT):
    return RX.match(PAT)
EOF
expect "a compiled name's constant pattern resolves at the compile, past a shadowing parameter" 1 run -- \
  "src/scoped.py:8 in check: '^a\$'"
rm "$proj/src/scoped.py"

# The clean corpus.
cat >"$proj/src/clean.py" <<'EOF'
import re
from pathlib import PurePath


class Holder:
    _RE = re.compile(r"^a$")
    PATTERN = r"^a$"

    def check(self, s):
        return self._RE.match(s), re.match(self.PATTERN, s)


def parameter(rx, s):
    return rx.match(s)


def shadowed(s):
    rx = re.compile(r"^a$")
    rx = re.compile(r"^b$")
    return rx.match(s)


def other(s, pattern):
    re.match(r"^a\Z", s)
    re.fullmatch(r"^a$", s)
    re.match(r"^a\$", s)
    re.match(r"^[$]", s)
    re.match(r"^[a-z]+", s)
    re.search(r"a$", s)
    re.search(r"a\Z", s)
    re.match(pattern, s)
    re.compile(r"^a$").fullmatch(s)
    return PurePath(s).match("*.py")


def local_constant(s):
    pattern = r"^a$"
    return re.match(pattern, s)


TWICE = "^a$"
TWICE = "^b$"
re.match(TWICE, "")
EOF
config "$table"
expect "a project holding only the clean shapes passes" 0 run -- "no anchored .match() or .search() beyond the 0 accepted function(s)."
rm "$proj/src/clean.py"

# Failure modes.
cat >"$proj/src/flagged.py" <<'EOF'
import re


def plain(s):
    return re.match("^a$", s)
EOF
config "$table" "$entry" "$file" "$fn" "$why"
expect "an accepted finding passes" 0 run -- "beyond the 1 accepted function(s)."
config "$table" "$entry" "$file" 'function = "gone"' "$why" "$entry" 'file = "src/missing.py"' 'function = "<module>"' "$why"
expect "stale entries fail, and the unaccepted call with them" 1 run -- \
  "ERROR: anchored .match() not accepted in devkit.toml: src/flagged.py:5 in plain: '^a\$'" \
  "ERROR: stale [[python.anchored-match.accepted]] entry, no anchored .match() or .search() in: src/flagged.py gone" \
  "ERROR: stale [[python.anchored-match.accepted]] entry, no anchored .match() or .search() in: src/missing.py <module>" \
  "To fix: use re.fullmatch (or \\A...\\Z), or accept the function with an [[python.anchored-match.accepted]] entry in devkit.toml (file, function and a reason); remove the stale entries from devkit.toml."
config "$table" "$entry" "$file" "$fn" "$why"
mv "$proj/src/flagged.py" "$work/flagged.py"
ln -s "$work/flagged.py" "$proj/src/flagged.py"
expect "a symlinked .py is skipped, so its accepted entry is stale" 1 run -- "ERROR: stale [[python.anchored-match.accepted]] entry"
rm "$proj/src/flagged.py"
config "$table"
expect "a project without Python files passes" 0 run -- "beyond the 0 accepted function(s)."

printf 'def broken(:\n' >"$proj/src/syntax.py"
expect "an unparseable file is an ERROR naming the file and the interpreter" 1 run -- \
  "ERROR: cannot parse src/syntax.py with Python $version ($exe): SyntaxError:" \
  "To fix: $remedy."
printf 'x = 1\0\n' >"$proj/src/syntax.py"
expect "a NUL byte is an ERROR naming the file" 1 run -- "ERROR: cannot parse src/syntax.py with Python $version ($exe): "
python3 -c 'print("x = " + "-" * 200000 + "1")' >"$proj/src/syntax.py"
expect "nesting too deep to parse is an ERROR naming the file" 1 run -- "ERROR: cannot parse src/syntax.py with Python $version ($exe): "
printf 'def broken(:\n' >"$proj/src/syntax.py"
config "$table" "$entry" 'file = "src/syntax.py"' "$fn" "$why"
expect "an entry for a file that does not parse is not also stale" 1 run -- "ERROR: cannot parse src/syntax.py"
absent "an entry for a file that does not parse is not also stale (no stale line)" "stale"
rm "$proj/src/syntax.py"
config "$table"

# A file that cannot be read is its own ERROR, and the same remedy.
if [[ $(id -u) != 0 ]]; then
  printf 'x = 1\n' >"$proj/src/unreadable.py"
  chmod 000 "$proj/src/unreadable.py"
  expect "an unreadable file is an ERROR naming the file" 1 run -- \
    "ERROR: cannot read src/unreadable.py: [Errno 13] Permission denied" "To fix: $remedy."
  rm -f "$proj/src/unreadable.py"
fi

# A file that parses is scanned however deep it nests: a long elif chain, and
# a long sum, each ending in a flagged call. 1500 levels parse on every
# python3 from 3.11 (3000 do not on 3.11 and 3.12), and are far past what the
# default recursion limit walks. 3000 unary minuses parse from 3.12, and on
# 3.11 only under the raised limit, which builds its tree under that limit.
python3 -c '
print("import re\n\n\ndef deep(x):\n    if x == 0:\n        pass")
for i in range(1, 1500):
    print(f"    elif x == {i}:\n        pass")
print("    return re.match(\"a$\", x)")' >"$proj/src/deep.py"
python3 -c 'print("import re\n\nx = 1" + "+1" * 1500 + "\nre.match(\"b$\", \"\")")' >"$proj/src/long.py"
python3 -c 'print("import re\n\nx = " + "-" * 3000 + "1\nre.match(\"c$\", \"\")")' >"$proj/src/unary.py"
expect "deep nesting that parses is walked to its last call" 1 run -- \
  "src/deep.py:3005 in deep: 'a\$'" "src/long.py:4 in <module>: 'b\$'" "src/unary.py:4 in <module>: 'c\$'"
absent "deep nesting that parses is no parse error" "cannot parse"
rm "$proj/src/deep.py" "$proj/src/long.py" "$proj/src/unary.py"

# An invalid escape's SyntaxWarning is ruff's to report: no warning, the scan goes on.
printf 'import re\n\nx = "\\d"\nre.match("c$", x)\n' >"$proj/src/escape.py"
expect "an invalid escape warns nothing and is still scanned" 1 run -- "src/escape.py:4 in <module>: 'c\$'"
absent "an invalid escape warns nothing" "SyntaxWarning"
PYTHONWARNINGS=error expect "an invalid escape parses under PYTHONWARNINGS=error" 1 run -- "src/escape.py:4 in <module>: 'c\$'"
rm "$proj/src/escape.py"

# A search after leading global inline flags is anchored at the start too.
printf 'import re\n\nre.search(r"(?i)^a$", "")\nre.search(r"(?i)(?m)^b$", "")\nre.search(r"(?i)c$", "")\n' >"$proj/src/flags.py"
expect "a search after leading inline flags is flagged" 1 run -- \
  "src/flags.py:3 in <module>: '(?i)^a\$'" "src/flags.py:4 in <module>: '(?i)(?m)^b\$'"
absent "an end-only search after inline flags is not flagged" "src/flags.py:5 "
rm "$proj/src/flags.py"

# The search's start anchor may follow whitespace, flags and group openers; a
# ^ inside a later group is no start anchor.
cat >"$proj/src/start.py" <<'PY'
import re

re.search(r"(?x) ^ [a-z]+ $", "")
re.search("(^[a-z]+$)", "")
re.search(r"(?:^a$)", "")
re.search(r"""
    ^ b $
""", "", re.X)
re.search("a(^b)$", "")
re.search("(?P<n>^c$)", "")
re.search("(?i-s:^d$)", "")
re.match("(^e$)", "")
PY
expect "a search whose ^ follows whitespace, flags or group openers is flagged" 1 run -- \
  "src/start.py:3 in <module>: '(?x) ^ [a-z]+ \$'" "src/start.py:4 in <module>: '(^[a-z]+\$)'" \
  "src/start.py:5 in <module>: '(?:^a\$)'" "src/start.py:6 in <module>: " \
  "src/start.py:10 in <module>: '(?P<n>^c\$)'" "src/start.py:11 in <module>: '(?i-s:^d\$)'" \
  "src/start.py:12 in <module>: '(^e\$)'"
absent "a ^ after other text is no start anchor" "src/start.py:9 "
rm "$proj/src/start.py"

# nonlocal rebinds the name in the nearest enclosing function only, so the
# module's compiled name is still bound once.
cat >"$proj/src/nonlocal.py" <<'PY'
import re

RX = re.compile(r"^a$")


def counter():
    RX = 0

    def bump():
        nonlocal RX
        RX += 1

    return bump


def check(s):
    return RX.match(s)
PY
expect "nonlocal in another function leaves a module compile resolvable" 1 run -- "src/nonlocal.py:17 in check: '^a\$'"
rm "$proj/src/nonlocal.py"

# global and nonlocal rebind a name only when the declaring function binds it.
cat >"$proj/src/declared.py" <<'PY'
import re

RX = re.compile(r"^a$")


def reads():
    global RX
    return RX


def check(s):
    return RX.match(s)
PY
expect "a global that only reads leaves the module compile resolvable" 1 run -- "src/declared.py:12 in check: '^a\$'"
cat >"$proj/src/declared.py" <<'PY'
import re

RX = re.compile(r"^a$")


def reset():
    global RX
    RX = re.compile("x")


def check(s):
    return RX.match(s)
PY
expect "a global that assigns makes the module name unresolvable" 0 run -- "beyond the 0 accepted function(s)."
cat >"$proj/src/declared.py" <<'PY'
import re


def f(s):
    rx = re.compile("^a$")

    def g():
        return rx.match(s)

    def h():
        nonlocal rx
        rx = None

    return rx.match(s), g, h
PY
expect "a nonlocal that assigns makes the outer name unresolvable, in the middle function too" 0 run -- \
  "beyond the 0 accepted function(s)."
cat >"$proj/src/declared.py" <<'PY'
import re


def f(s):
    rx = re.compile("^a$")

    def g():
        def h():
            nonlocal rx
            return rx

        return h

    return rx.match(s), g
PY
expect "a nonlocal that does not assign leaves the outer name resolvable" 1 run -- "src/declared.py:14 in f: '^a\$'"
rm "$proj/src/declared.py"

# "import re.sub" binds re to the module.
printf 'import re\nimport re._parser\n\nre.match("^a$", "")\n' >"$proj/src/sub.py"
expect "import re._parser still binds re to the module" 1 run -- "src/sub.py:4 in <module>: '^a\$'"
printf 'import re._parser as p\n\np.match("^a$", "")\n' >"$proj/src/sub.py"
expect "import re._parser as p binds something else" 0 run -- "beyond the 0 accepted function(s)."
rm "$proj/src/sub.py"

# Shapes each resolved by one visitor or one scanner rule.
printf '\xef\xbb\xbfimport re\n\nre.match("^a$", "")\n' >"$proj/src/bom.py"
printf '# -*- coding: latin-1 -*-\n# caf\xe9\nimport re\n\nre.match("^b$", "")\n' >"$proj/src/latin.py"
cat >"$proj/src/shapes.py" <<'PY'
import re

PAT: str = r"^c$"
re.match(PAT, "")


def walrus(s):
    if (rx := re.compile("^d$")):
        return rx.match(s)


re.match("[]$]$", "")


class Outer:
    re.match("e$", "")


def lam():
    return lambda s: re.match("f$", s)
PY
expect "a BOM, a coding cookie, an annotated constant, a walrus and the odd shapes are scanned" 1 run -- \
  "src/bom.py:3 in <module>: '^a\$'" "src/latin.py:5 in <module>: '^b\$'" \
  "src/shapes.py:4 in <module>: '^c\$'" "src/shapes.py:9 in walrus: '^d\$'" \
  "src/shapes.py:12 in <module>: '[]\$]\$'" "src/shapes.py:16 in Outer: 'e\$'" \
  "src/shapes.py:20 in lam.<lambda>: 'f\$'"
absent "none of those files fails to parse" "cannot parse"
rm "$proj/src/bom.py" "$proj/src/latin.py" "$proj/src/shapes.py"

# Every other way to bind a name makes it bound twice, so its calls are skipped.
cat >"$proj/src/rebound.py" <<'PY'
import re
import os as G

A = re.compile(r"^a$")
B = re.compile(r"^b$")
C = re.compile(r"^c$")
D = re.compile(r"^d$")
E = re.compile(r"^e$")
F = re.compile(r"^f$")
G = re.compile(r"^g$")
H = re.compile(r"^h$")


def rebind():
    global A
    A = None


for B in ():
    pass
with open(__file__) as C:
    pass
try:
    pass
except OSError as D:
    pass
match 1:
    case E:
        pass
if F := None:
    pass
[H for H in ()]


def use(s):
    return A.match(s), B.match(s), C.match(s), D.match(s), E.match(s), F.match(s), G.match(s), H.match(s)
PY
expect "global, for, with, except, match, walrus, import and comprehension rebinds are skipped" 0 run -- \
  "beyond the 0 accepted function(s)."
rm "$proj/src/rebound.py"

mkdir -p "$work/nogit/src"
printf '%s\n' "$table" >"$work/nogit/devkit.toml"
PROJECT_ROOT=$work/nogit GIT_CEILING_DIRECTORIES=$work expect "a project outside a git work tree fails run" 1 run -- \
  "ERROR: git cannot list the files in $work/nogit: "
PROJECT_ROOT=$work/nogit GIT_CEILING_DIRECTORIES=$work expect "a project outside a git work tree fails check-config" 1 check-config -- \
  "ERROR: git cannot list the files in $work/nogit: "
config "$table" "$entry" "$file" "$fn"
expect "run validates the config before it scans" 1 run -- "entry 1 (src/flagged.py plain) needs a reason"
expect "an unknown command exits 2" 2 lint -- "usage: anchored_match.py {check-config|run}"
expect "run with an argument exits 2" 2 run extra -- "usage: anchored_match.py {check-config|run}"
expect "no command exits 2" 2 -- "usage: anchored_match.py {check-config|run}"

[[ $fails == 0 ]]
