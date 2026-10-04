#!/bin/bash

set -euo pipefail

# An empty PROJECT_ROOT would match every process below.
cd "${PROJECT_ROOT:?}"

# pids of this project's Quarkus and Maven processes: JVMs whose command line names the project
# directory or a path inside it (-Dmaven.multiModuleProjectDirectory, target/ jars, ...). JVMs
# only, so an editor or shell with the project open survives.
project_pids() {
    local pid comm
    for pid in $(pgrep -f 'quarkus|maven' || :); do
        comm=$(ps -o comm= -p "$pid" || :)
        [[ ${comm##*/} == java && "$(ps -o args= -p "$pid" || :) " == *"$PROJECT_ROOT"[/\ ]* ]] && echo "$pid"
    done
    return 0
}

pids=$(project_pids)
if [[ -n $pids ]]; then
    echo "Stopping this project's Quarkus/Maven processes..."
    # shellcheck disable=SC2086 # one argument per pid
    kill $pids 2> /dev/null || :
    sleep 2
    pids=$(project_pids)
    if [[ -n $pids ]]; then
        echo "Force killing the remaining ones..."
        # shellcheck disable=SC2086
        kill -9 $pids 2> /dev/null || :
    fi
    echo "Quarkus/Maven processes stopped."
else
    echo "No Quarkus/Maven processes of this project found."
fi

# The project's own compose services only: `docker compose down` finds the compose file and the
# compose project name in this directory, and leaves every other container alone.
# The file check keeps compose from walking up to a parent directory's compose file.
if [[ ! -e compose.yaml && ! -e compose.yml && ! -e docker-compose.yaml && ! -e docker-compose.yml ]]; then
    echo "No compose file; no containers to stop."
elif command -v docker &> /dev/null && docker info &> /dev/null; then
    echo "Running docker compose down..."
    docker compose down --remove-orphans || :
else
    echo "Docker is not installed or not running. Skipping docker compose down."
fi

echo "Process cleanup complete."
