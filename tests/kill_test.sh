#!/usr/bin/env bash
# Tests for scripts/java/kill.sh: stand-in processes, run as "java" with a
# command line naming a project, and kill.sh with PROJECT_ROOT at a temp
# project.
# Only the project's own JVM may die, and one it cannot signal must be
# reported, not passed over. Prints PASS/FAIL per process.
set -euo pipefail

kill_sh=$(cd "$(dirname "$0")/.." && pwd)/scripts/java/kill.sh
work=$(mktemp -d)
pids=()
trap 'kill "${pids[@]}" 2> /dev/null || :; rm -rf "$work"' EXIT
mkdir -p "$work/proj/maven/bin" "$work/other/maven/bin" "$work/proj2/maven/bin"
fails=0

# The stand-ins run the way a real JVM does: the executable is a symlink to
# sleep named java, in a directory of the project it stands for, so its
# command line names that project ("<project>/maven/bin/java 300"). ps shows
# argv[0] as the command on macOS and the executable's name on Linux; a
# stand-in that put the whole command line into argv[0] (exec -a) would show
# on macOS as a command named after the project directory, which no real JVM
# does.
for d in proj other proj2; do ln -s "$(command -v sleep)" "$work/$d/maven/bin/java"; done

labels=()
spawn() { # spawn LABEL PROJECT-DIR [non-jvm]: a JVM stand-in (or sleep) naming PROJECT-DIR
  if [[ ${3:-} == non-jvm ]]; then
    bash -c 'exec -a "sleep $1/maven" "$0" 300' "$(command -v sleep)" "$2" &
  else
    "$2/maven/bin/java" 300 &
  fi
  pids+=($!) labels+=("$1")
}

spawn "this project's JVM is killed" "$work/proj"
spawn "another project's JVM survives" "$work/other"
spawn "a JVM in a sibling path sharing the prefix survives" "$work/proj2"
spawn "a non-JVM naming the project survives" "$work/proj" non-jvm
sleep 0.5

PROJECT_ROOT=$work/proj "$kill_sh" > "$work/kill.log" 2>&1 || {
  cat "$work/kill.log"
  fails=$((fails + 1))
}
for i in "${!pids[@]}"; do
  alive=yes want=yes
  kill -0 "${pids[i]}" 2> /dev/null || alive=no
  [[ $i != 0 ]] || want=no
  if [[ $alive == "$want" ]]; then
    echo "PASS ${labels[i]}"
  else
    echo "FAIL ${labels[i]} (alive: $alive)"
    fails=$((fails + 1))
  fi
done

# A JVM kill.sh cannot signal, as the kernel refuses (EPERM) another user's
# process: bash imports an exported function, and a function named kill
# shadows the builtin in kill.sh. The subshell keeps it out of this shell.
spawn "an unsignalable JVM of this project is reported" "$work/proj"
sleep 0.5
rc=0
(
  # shellcheck disable=SC2317,SC2329 # called by kill.sh, through export -f
  kill() { # refuses $KILL_REFUSES and signals the rest
    local arg args=() rc=0
    for arg; do
      if [[ $arg == "$KILL_REFUSES" ]]; then rc=1; else args+=("$arg"); fi
    done
    builtin kill ${args[@]+"${args[@]}"} || rc=$?
    return "$rc"
  }
  export -f kill
  KILL_REFUSES=${pids[-1]} PROJECT_ROOT=$work/proj exec "$kill_sh"
) > "$work/kill.log" 2>&1 || rc=$?
if [[ $rc == 1 ]] && grep -q "survived SIGKILL" "$work/kill.log" &&
  grep -qw "${pids[-1]}" "$work/kill.log" && grep -q "No compose file" "$work/kill.log" &&
  kill -0 "${pids[-1]}"; then
  echo "PASS ${labels[-1]}, and the compose step still runs"
else
  echo "FAIL ${labels[-1]} (exit $rc)"
  cat "$work/kill.log"
  fails=$((fails + 1))
fi

[[ $fails == 0 ]]
