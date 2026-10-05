#!/bin/bash

# Sourced by scripts that run devkit's Python helpers.

# python3_floor: fail with one ERROR line on stderr unless python3 is 3.11 or
# later, the floor docs/contract.md sets for the helpers. Below it they end in a
# traceback instead: tomllib is new in 3.11, `X | None` annotations in 3.10.
python3_floor() {
  local version
  version=$(python3 -c 'import platform, sys; print(platform.python_version()); sys.exit(sys.version_info < (3, 11))' 2>/dev/null) && return
  echo "ERROR: devkit's Python helpers need python3 3.11 or later; found ${version:-no working python3 on PATH}." >&2
  return 1
}
