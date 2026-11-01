#!/usr/bin/env bash
# Tests for devkit's own top-level Makefile, offline: how it selects GATES.
# The real Makefile is copied into a temp project whose devkitw is a stub that
# records its call and prints a stub tree, so "release" means the stub ran and
# "tree" means it did not; nothing is fetched. Covered: check and check-devkit,
# alone or together, select release; lint-repo, a bare make and check-versions
# select tree; check beside a goal other than check-devkit, or with GATES=tree
# on the command line or in the environment, fails with the release-only
# message; an explicit GATES=release is honoured and an unknown GATES fails.
# check-versions really runs, over a stub python3 and two empty parent POMs:
# it visits every parent though one fails, fails when the Python floor is not
# met before visiting any, and does so even with rc=0 in the environment.
# Prints PASS/FAIL per check.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "${work:?}"' EXIT
proj=$work/proj
called=$work/devkitw.called
fails=0

mkdir -p "$proj" "$work/stub"
cp "$root/Makefile" "$proj/Makefile"
ln -s "$root/make" "$proj/make"
ln -s "$work/stub" "$proj/.devkit"
ln -s "$root/make" "$work/stub/make"
printf '#!/usr/bin/env bash\necho called >>%q\necho %q\n' "$called" "$work/stub" >"$proj/devkitw"
chmod +x "$proj/devkitw"

mkdir -p "$proj/scripts/lib" "$proj/scripts/java" "$proj/java/a" "$proj/java/b" "$work/bin"
ln -s "$root/scripts/lib/python.sh" "$proj/scripts/lib/python.sh"
: >"$proj/scripts/java/version_check.py"
: >"$proj/java/a/pom.xml"
: >"$proj/java/b/pom.xml"
# The stub python3: -c is the floor probe, anything else a helper run.
cat >"$work/bin/python3" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do [[ $a == -c ]] && exit "${STUB_FLOOR:-0}"; done
[[ -n ${STUB_FAIL:-} && $PROJECT_ROOT == "$STUB_FAIL" ]] && exit 1
echo "checked $PROJECT_ROOT"
STUB
chmod +x "$work/bin/python3"

out=
rc=0
run() { # run [VAR=VALUE...] -- MAKE_ARGS...: sets out, rc
  local envs=()
  while [[ $1 != -- ]]; do envs+=("$1"); shift; done
  shift
  : >"$called"
  rc=0
  out=$(env -u MAKEFLAGS -u MFLAGS -u GNUMAKEFLAGS -u MAKELEVEL -u MAKEFILES -u GATES \
    ${envs[@]+"${envs[@]}"} make -n -C "$proj" "$@" 2>&1) || rc=$?
}

run_real() { # run_real [VAR=VALUE...]: make check-versions for real, stub python3
  rc=0
  out=$(env -u MAKEFLAGS -u MFLAGS -u GNUMAKEFLAGS -u MAKELEVEL -u MAKEFILES -u GATES \
    PATH="$work/bin:$PATH" ${1+"$@"} make -C "$proj" check-versions 2>&1) || rc=$?
}
has() { [[ $out == *"$1"* ]]; }

verdict() { # verdict DESCRIPTION CONDITION_RESULT
  if [[ $2 == ok ]]; then echo "PASS $1"; else echo "FAIL $1" && fails=$((fails + 1)); fi
}
mode() { [[ -s $called ]] && echo release || echo tree; }

ok_mode() { # ok_mode DESCRIPTION EXPECTED_MODE: rc 0 and that mode
  verdict "$1" "$( ((rc == 0)) && [[ $(mode) == "$2" ]] && echo ok || echo no)"
}
fails_with() { # fails_with DESCRIPTION MESSAGE: rc != 0, message, stub unused
  verdict "$1" "$( ((rc != 0)) && [[ $out == *"$2"* ]] && [[ $(mode) == tree ]] && echo ok || echo no)"
}
msg='make check applies to GATES=release only'

run -- check
ok_mode "make check selects release" release
run -- check-devkit
ok_mode "make check-devkit selects release" release
run -- check check-devkit
ok_mode "make check check-devkit selects release" release
run -- lint-repo
ok_mode "make lint-repo selects tree" tree
run --
ok_mode "a bare make selects tree" tree
run -- check-versions
ok_mode "make check-versions selects tree" tree
run -- check lint-repo
fails_with "make check lint-repo fails with the release-only message" "$msg"
run -- GATES=tree check
fails_with "make GATES=tree check fails with the release-only message" "$msg"
run GATES=tree -- check
fails_with "GATES=tree in the environment with check fails likewise" "$msg"
run -- GATES=release lint-repo
ok_mode "make GATES=release lint-repo selects release" release
run -- GATES=bogus lint-repo
fails_with "GATES=bogus fails naming the choices" "GATES must be tree or release"

run_real
verdict "check-versions passes and visits both parents" "$( ((rc == 0)) && has '== java/a' && has '== java/b' && has 'checked java/a' && has 'checked java/b' && echo ok || echo no)"
run_real STUB_FAIL=java/a
verdict "check-versions fails but still visits the parent after a failing one" "$( ((rc != 0)) && has 'checked java/b' && echo ok || echo no)"
run_real STUB_FLOOR=1
verdict "check-versions fails below the Python floor before any parent" "$( ((rc != 0)) && ! has '== java/' && echo ok || echo no)"
run_real STUB_FLOOR=1 rc=0
verdict "check-versions fails below the floor even with rc=0 in the environment" "$( ((rc != 0)) && ! has '== java/' && echo ok || echo no)"

((fails == 0))
