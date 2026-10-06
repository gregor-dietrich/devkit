#!/bin/bash

# Sourced by the scripts/python/*.sh after they cd to $PROJECT_ROOT. Exports UV_CMD, a uv of
# exactly the version uv.lock pins (its uv package), the first of:
#   1. the first uv on PATH that reports that version and is not the one inside the project's
#      .venv (nor resolves into it);
#   2. devkit's per-user copy, ${XDG_CACHE_HOME:-$HOME/.cache}/devkit/uv/<version>/bin/uv;
#   3. with UV_BOOTSTRAP=true (make install only): that copy, installed first from the uv wheel
#      uv.lock pins, hash-verified, by pip in a throwaway venv.
# Else it fails. Never the uv inside .venv: install replaces that environment, and check judges
# it.

# shellcheck source=SCRIPTDIR/python.sh
. "$DEVKIT/scripts/lib/python.sh"
python3_floor || exit 1
UV_PIN=$(python3 "$DEVKIT/scripts/python/uv_project.py" uv-version) || exit
uv_root=${XDG_CACHE_HOME:-$HOME/.cache}/devkit/uv
[[ $uv_root == /* ]] || {
    echo "ERROR: the uv cache root $uv_root is not an absolute path; fix XDG_CACHE_HOME or HOME." >&2
    exit 1
}
uv_dir=$uv_root/$UV_PIN

uv_is_pin() { # uv_is_pin PATH: PATH runs and reports the pinned version ("uv X" or "uv X (...)")
    local version
    version=$("$1" --version 2> /dev/null) || return 1
    [[ $version == "uv $UV_PIN" || $version == "uv $UV_PIN ("*")" ]]
}

uv_bootstrap() { # install uv $UV_PIN into $uv_dir; a subshell, so its traps stay its own
    (
        mkdir -p "$uv_root"
        tmp=$(mktemp -d "$uv_root/.tmp.XXXXXX")
        trap 'rm -rf "$tmp"' EXIT
        trap 'exit 1' HUP INT TERM
        echo "Installing uv $UV_PIN, hash-verified from uv.lock, into $uv_dir ..."
        # A file, not a pipe: pip installs nothing, and succeeds, from an empty requirements list.
        python3 "$DEVKIT/scripts/python/uv_project.py" uv-requirements > "$tmp/requirements.txt"
        # -I: else the cwd, the project root, comes first on sys.path, and a project venv.py or
        # pip.py would run in place of the module.
        python3 -I -m venv "$tmp/venv" || {
            echo "ERROR: python3 -m venv failed; install python3's venv module, or put uv $UV_PIN on PATH." >&2
            exit 1
        }
        "$tmp/venv/bin/python" -I -m pip install --quiet --disable-pip-version-check --require-hashes \
            --only-binary=:all: --no-deps -r "$tmp/requirements.txt" || {
            echo "ERROR: pip could not install uv $UV_PIN as uv.lock pins it; see its output above." >&2
            exit 1
        }
        mkdir "$tmp/bin"
        cp "$tmp/venv/bin/uv" "$tmp/bin/uv"
        chmod a-w "$tmp/bin/uv" # read-only, like the devkit checkout
        rm -rf "$tmp/venv" "$tmp/requirements.txt"
        mv "$tmp" "$uv_dir"
        rm -rf "${uv_dir:?}/${tmp##*/}" # a concurrent run won: mv nested ours in it
    )
}

uv_refused() { # uv_refused PATH: PATH is the uv inside .venv, or resolves into .venv; unsure refuses
    local real venv
    [[ ! $1 -ef .venv/bin/uv ]] && real=$(realpath "$1") || return 0
    [[ -e .venv || -L .venv ]] || return 1
    venv=$(cd ./.venv && pwd -P) || return 0
    [[ $real == "$venv/"* ]]
}

uv_on_path() { # set UV_CMD to the first uv on PATH that uv_refused lets through and reports the pin
    local candidate
    while IFS= read -r candidate; do
        ! uv_refused "$candidate" && uv_is_pin "$candidate" && UV_CMD=$candidate && return
    done < <(type -aP uv)
    return 1
}

if uv_on_path; then
    : # UV_CMD is the uv on PATH
elif UV_CMD=$uv_dir/bin/uv; [[ -e $uv_dir || -L $uv_dir ]]; then
    uv_is_pin "$UV_CMD" || {
        echo "ERROR: $UV_CMD does not report uv $UV_PIN; remove $uv_dir and run make install." >&2
        exit 1
    }
elif [[ ${UV_BOOTSTRAP:-} == true ]]; then
    uv_bootstrap
    uv_is_pin "$UV_CMD" || {
        echo "ERROR: the uv installed into $uv_dir does not report uv $UV_PIN; remove $uv_dir and retry." >&2
        exit 1
    }
else
    echo "ERROR: uv $UV_PIN not found, neither on PATH nor in $uv_dir; run make install." >&2
    exit 1
fi
export UV_CMD
# uv would sync UV_PROJECT_ENVIRONMENT, but get_venv.sh and every target use the project's .venv.
unset UV_PROJECT_ENVIRONMENT
