#!/bin/bash

# Sourced by the scripts that run a Node.js tool devkit pins: a devkit directory (markdown/,
# jscpd/) whose package.json and package-lock.json are the tool's closure (docs/contract.md).

# shellcheck source=SCRIPTDIR/sha256.sh
. "$DEVKIT/scripts/lib/sha256.sh"

node_closure_fail() {
    echo "ERROR: $*" >&2
    exit 1
}

# node_closure DIR BIN LABEL: set NODE_TOOL to the BIN executable of DIR's closure, after
# checking node against DIR/package.json's engines.node; installs the closure once per
# lockfile, read-only, at ${XDG_CACHE_HOME:-$HOME/.cache}/devkit/tools/BIN-<key>. LABEL, the
# gate, names it in messages. Exits with one ERROR line on failure; call it as a statement.
node_closure() {
    local dir=$1 name=$2 label=$3 out said floor package found version versions root key cache
    # Node.js at or above the closure's floor, engines.node; the package is its dependency.
    out=$(python3 -I -c 'import json, sys; p = json.load(open(sys.argv[1])); print(p["engines"]["node"], *p["dependencies"])' \
        "$dir/package.json" 2>/dev/null) || out=
    read -r floor package <<<"$out"
    [[ $floor =~ ^\>=([0-9]+\.[0-9]+\.[0-9]+)$ && -n $package ]] ||
        node_closure_fail "$dir/package.json needs engines.node of the form '>=X.Y.Z' and the tool's package in dependencies"
    floor=${BASH_REMATCH[1]}
    command -v node >/dev/null || node_closure_fail "node not found; $label needs Node.js >= $floor and npm on PATH."
    found=$(node --version 2>/dev/null) || found=
    version=${found#v}
    version=${version%%-*} # a prerelease (-nightly..., -rc...) counts as its release
    [[ $version =~ ^[0-9]+(\.[0-9]+)*$ ]] ||
        node_closure_fail "cannot read a version from 'node --version' ('$found'); $label needs Node.js >= $floor."
    printf -v versions '%s\n%s' "$floor" "$version"
    [[ $versions == "$(sort -V <<<"$versions")" ]] ||
        node_closure_fail "Node.js $found on PATH is below $floor, which devkit's $name closure requires."

    # The pinned closure, installed once per lockfile into the user's cache.
    root=${XDG_CACHE_HOME:-$HOME/.cache}/devkit/tools
    [[ $root == /* ]] || node_closure_fail "cache root $root is not an absolute path"
    key=$(sha256_of "$dir/package.json" "$dir/package-lock.json" 2>/dev/null) ||
        node_closure_fail "cannot hash $dir's package files; $label needs sha256sum or shasum to key its cache"
    cache=$root/$name-${key:0:16}
    NODE_TOOL=$cache/node_modules/.bin/$name
    if [[ -e $cache || -L $cache ]]; then
        [[ -x $NODE_TOOL ]] || node_closure_fail "$cache is incomplete; remove it and retry"
        return 0
    fi
    command -v npm >/dev/null || node_closure_fail "npm not found; $label needs it on PATH to install $package once."
    mkdir -p "$root"
    ( # a subshell, so its traps stay its own
        stage=$(mktemp -d "$root/.tmp.XXXXXX")
        trap 'rm -rf "$stage"' EXIT
        trap 'exit 1' HUP INT TERM
        cp "$dir/package.json" "$dir/package-lock.json" "$stage/"
        echo "$label: installing $package into $cache..."
        # --include=optional beats an omit=optional in the user's npm config: jscpd's binary
        # is an optional, per-platform dependency.
        (cd "$stage" && NPM_CONFIG_UPDATE_NOTIFIER=false npm ci --ignore-scripts --no-audit --no-fund \
            --include=optional --loglevel=error) ||
            node_closure_fail "cannot install $package (npm ci failed; the first run needs the npm registry)"
        [[ -x $stage/node_modules/.bin/$name ]] ||
            node_closure_fail "npm ci did not install $name (check npm's bin-links setting)"
        said=$(cd "$stage" && "$stage/node_modules/.bin/$name" --version 2>&1) ||
            node_closure_fail "the $name npm ci installed does not run (${said%%$'\n'*}); nothing was cached, fix that and retry"
        # Read-only, so an edit inside the cache cannot change every project's gate.
        find "$stage" -type f -exec chmod a-w {} +
        mv "$stage" "$cache"
        rm -rf "${cache:?}/${stage##*/}" # a concurrent run won: mv nested ours in it
    )
}
