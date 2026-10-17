#!/bin/bash

# Sourced by the scripts/python/*.sh after they cd to $PROJECT_ROOT. Exports UV_CMD, devkit's
# per-user copy of exactly the uv uv.lock pins (its uv package):
#   ${XDG_CACHE_HOME:-$HOME/.cache}/devkit/tools/uv-<version>-<os>-<arch>-<key>/bin/uv
# where <os>-<arch> is uname's (a cache shared by machines of another platform keeps a copy each,
# as gitleaks' does) and <key> is the first 16 hex digits of the sha256 of the requirements file
# pip installs it from (the version and every wheel hash uv.lock lists for it). The copy is installed only under
# UV_BOOTSTRAP=true (make install), by pip in a throwaway venv, from the index pip's own
# configuration names, and pip accepts only a wheel whose hash the lock lists. Else a missing copy
# fails, naming make install.
#
# Why it differs from the pinned Maven bootstrap (#131, #44): the pin and the hashes are the
# project's, so pip matches the wheel by its tags (fetch.sh fits a tarball devkit pins). Only
# install bootstraps: check and audit need .venv, which only install creates, lint, test and
# format run no uv, and check stays offline, so Maven's reason for fetching lazily does not apply.
#
# Where it no longer differs: never a uv on PATH (it came first until v0.7.x; a matching version
# is not the same bits, and uv enforces uv.lock's hashes as Maven enforces java/checksums), never
# the uv inside .venv (install replaces that environment, and check judges it). The key holds the
# hashes because the cache is shared and the lock is per project: keyed by version alone, the
# first project decided what every later one ran. pip's configuration keeps choosing the index (a
# mirror, a private index, a wheel directory) because the lock's hashes decide what is installed,
# so pinning PyPI or the lock's source adds no trust and breaks routes.

# shellcheck source=SCRIPTDIR/python.sh
. "$DEVKIT/scripts/lib/python.sh"
python3_floor || exit 1
# shellcheck source=SCRIPTDIR/sealed_dir.sh
. "$DEVKIT/scripts/lib/sealed_dir.sh"
# shellcheck source=SCRIPTDIR/sha256.sh
. "$DEVKIT/scripts/lib/sha256.sh"
UV_PIN=$(python3 -I "$DEVKIT/scripts/python/uv_project.py" uv-version) || exit
uv_reqs=$(python3 -I "$DEVKIT/scripts/python/uv_project.py" uv-requirements) || exit
uv_tools=${XDG_CACHE_HOME:-$HOME/.cache}/devkit/tools
[[ $uv_tools == /* ]] || {
    echo "ERROR: the tools cache root $uv_tools is not an absolute path; fix XDG_CACHE_HOME or HOME." >&2
    exit 1
}
uv_key=$(printf '%s\n' "$uv_reqs" | sha256_of -) || exit
uv_platform=$(uname -s)-$(uname -m) || exit
uv_dir=$uv_tools/uv-$UV_PIN-$uv_platform-${uv_key:0:16}
UV_CMD=$uv_dir/bin/uv

uv_is_pin() { # uv_is_pin PATH: PATH runs and reports the pinned version ("uv X" or "uv X (...)")
    local version
    version=$("$1" --version 2> /dev/null) || return 1
    [[ $version == "uv $UV_PIN" || $version == "uv $UV_PIN ("*")" ]]
}

uv_bootstrap() { # install uv $UV_PIN into $uv_dir; a subshell, so its traps stay its own
    (
        mkdir -p "$uv_tools"
        tmp=$(mktemp -d "$uv_tools/.tmp.XXXXXX") || exit 1
        trap 'sealed_remove "$tmp"' EXIT
        trap 'exit 1' HUP INT TERM
        echo "Installing uv $UV_PIN, hash-verified from uv.lock, into $uv_dir ..."
        # A file, not a pipe: pip installs nothing, and succeeds, from an empty requirements list.
        # The same bytes the key hashes.
        printf '%s\n' "$uv_reqs" > "$tmp/requirements.txt"
        # -I: else the cwd, the project root, comes first on sys.path, and a project venv.py or
        # pip.py would run in place of the module.
        python3 -I -m venv "$tmp/venv" || {
            echo "ERROR: python3 -m venv failed; install python3's venv module." >&2
            exit 1
        }
        "$tmp/venv/bin/python" -I -m pip install --quiet --disable-pip-version-check --require-hashes \
            --only-binary=:all: --no-deps -r "$tmp/requirements.txt" || {
            echo "ERROR: pip could not install uv $UV_PIN as uv.lock pins it; see its output above. pip fetches from its own index (PyPI unless pip.conf or PIP_INDEX_URL names another) and installs only a wheel whose sha256 uv.lock lists." >&2
            exit 1
        }
        [[ -x $tmp/venv/bin/uv ]] || {
            echo "ERROR: pip reported success but installed no uv into its throwaway venv; PIP_TARGET, PIP_PREFIX, PIP_ROOT or PIP_DRY_RUN (in the environment or pip.conf) redirect or skip it: unset them for make install." >&2
            exit 1
        }
        mkdir "$tmp/bin"
        cp "$tmp/venv/bin/uv" "$tmp/bin/uv"
        rm -rf "$tmp/venv" "$tmp/requirements.txt"
        # Read-only, directories too, like the devkit checkout.
        sealed_place "$tmp" "$uv_dir" || {
            echo "ERROR: cannot move the installed uv $UV_PIN into $uv_dir." >&2
            exit 1
        }
    )
}

if [[ ! -e $uv_dir && ! -L $uv_dir ]]; then
    if [[ ${UV_BOOTSTRAP:-} == true ]]; then
        # || exit: fail closed even where the caller's errexit is off (a || list, a sourcing test).
        uv_bootstrap || exit
    else
        echo "ERROR: uv $UV_PIN, as uv.lock pins it, is not installed in $uv_dir; run make install." >&2
        exit 1
    fi
fi
uv_is_pin "$UV_CMD" || {
    echo "ERROR: $UV_CMD does not report uv $UV_PIN; remove $uv_dir (chmod -R u+w '$uv_dir'; rm -rf '$uv_dir') and run make install." >&2
    exit 1
}
export UV_CMD
# uv would sync UV_PROJECT_ENVIRONMENT, but get_venv.sh and every target use the project's .venv.
unset UV_PROJECT_ENVIRONMENT
