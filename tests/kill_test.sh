#!/usr/bin/env bash
# Tests for scripts/java/kill.sh: stand-in processes, run as "java" with a
# Maven-like command line, and kill.sh with PROJECT_ROOT at a temp project.
# Only the project's own JVM may die. Prints PASS/FAIL per process.
set -euo pipefail

kill_sh=$(cd "$(dirname "$0")/.." && pwd)/scripts/java/kill.sh
work=$(mktemp -d)
pids=()
trap 'kill "${pids[@]}" 2> /dev/null || :; rm -rf "$work"' EXIT
mkdir "$work/proj" "$work/bin"
ln -s "$(command -v sleep)" "$work/bin/java"
fails=0

labels=()
spawn() { # spawn LABEL EXECUTABLE PROJECT-PATH: EXECUTABLE, with args that name PROJECT-PATH
  bash -c 'exec -a "java -Dmaven.multiModuleProjectDirectory=$1" "$0" 300' "$2" "$3" &
  pids+=($!) labels+=("$1")
}

spawn "this project's JVM is killed" "$work/bin/java" "$work/proj"
spawn "another project's JVM survives" "$work/bin/java" "$work/other"
spawn "a JVM in a sibling path sharing the prefix survives" "$work/bin/java" "$work/proj2"
spawn "a non-JVM naming the project survives" "$(command -v sleep)" "$work/proj"
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

[[ $fails == 0 ]]
