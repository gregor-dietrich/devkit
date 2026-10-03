#!/bin/bash
# Splitting `docker ps -q` into one argument per container ID is intended.
# shellcheck disable=SC2046

set -euo pipefail

cd "$PROJECT_ROOT"

# Check if docker is available
docker_available() {
    command -v docker &> /dev/null && docker ps &> /dev/null
    return $?
}

if pgrep -f "quarkus" > /dev/null; then
    echo "Killing Quarkus processes..."
    sudo pkill -f "quarkus" > /dev/null || true
    sleep 2
    if pgrep -f "quarkus" > /dev/null; then
        echo "Force killing remaining Quarkus processes..."
        sudo pkill -f -9 "quarkus" > /dev/null || true
    fi
    echo "Quarkus processes killed."
else
    echo "No Quarkus processes found."
fi

if pgrep -f "maven" > /dev/null; then
    echo "Killing Maven processes..."
    sudo pkill -f "maven" > /dev/null || true
    sleep 1
    echo "Maven processes killed."
else
    echo "No Maven processes found."
fi

if docker_available; then
    if [ "$(docker ps -q)" ]; then
        echo "Stopping all Docker containers..."
        docker stop $(docker ps -q) > /dev/null || true
        sleep 3

        if [ "$(docker ps -q)" ]; then
            echo "Force killing remaining Docker containers..."
            docker kill $(docker ps -q) > /dev/null || true
        fi

        echo "Docker containers stopped."
    else
        echo "No running Docker containers found."
    fi

    if [ "$(docker ps -a -q)" ]; then
        echo "Removing all Docker containers..."
        docker rm $(docker ps -a -q) > /dev/null || true
        echo "All Docker containers removed."
    fi

    # Also handle docker-compose if exists
    if [ -f docker-compose.yml ]; then
        echo "Running docker compose down..."
        docker compose -f docker-compose.yml down || true
    fi
else
    echo "Docker is not installed or not running. Skipping Docker cleanup."
fi

echo "Process cleanup complete."
