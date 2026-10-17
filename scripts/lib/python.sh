#!/bin/bash

# Sourced by scripts that run devkit's Python helpers.

# python3_floor: fail with one ERROR line on stderr unless python3 is 3.11 or
# later, the floor docs/contract.md sets for the helpers. Below it they end in a
# traceback instead: tomllib is new in 3.11, `X | None` annotations in 3.10.
python3_floor() { python_floor python3 "python3 on PATH"; }

# python_floor PYTHON WHAT [REMEDY]: the same for PYTHON, named WHAT when it does
# not run; REMEDY, if given, ends the line.
python_floor() {
  local version
  version=$("$1" -I -c 'import platform, sys; print(platform.python_version()); sys.exit(sys.version_info < (3, 11))' 2>/dev/null) && return
  echo "ERROR: devkit's Python helpers need $1 3.11 or later; found ${version:-no working $2}.${3:+ $3}" >&2
  return 1
}
