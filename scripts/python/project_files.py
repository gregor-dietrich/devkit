"""A git project's devkit.toml [python] table and Python files, shared by the helpers that scan them."""

import os
import subprocess
import tomllib
from pathlib import Path
from typing import Any


class Failure(Exception):
    """A check that failed; its message is the ERROR line."""


def python_table(root: Path) -> Any:
    """devkit.toml's [python] table, None when it has none."""
    try:
        with (root / "devkit.toml").open("rb") as handle:
            return tomllib.load(handle).get("python")
    except FileNotFoundError as exc:
        raise Failure(f"no devkit.toml in {root}.") from exc
    except (OSError, ValueError) as exc:  # TOMLDecodeError subclasses ValueError
        raise Failure(f"cannot read devkit.toml: {exc}") from exc


def python_files(root: Path, tops: list[Path]) -> list[Path]:
    """The *.py files git lists in root (tracked, plus untracked ones the project does not ignore)
    under tops, each once; a tracked file deleted from disk, and a symlink, are skipped. The
    user's global excludes (core.excludesFile) do not apply.
    """
    command = ["git", "-c", "core.excludesFile=/dev/null", "ls-files", "-z", "--cached", "--others", "--exclude-standard"]
    try:
        listed = subprocess.run(command, cwd=root, capture_output=True, check=False)
    except OSError as exc:
        raise Failure(f"git cannot list the files in {root}: {exc}") from exc
    if listed.returncode != 0:
        said = os.fsdecode(listed.stderr).strip().partition("\n")[0]
        raise Failure(f"git cannot list the files in {root}: {said or f'exit {listed.returncode}'}")
    found = {root / os.fsdecode(name) for name in listed.stdout.split(b"\0") if name.endswith(b".py")}
    return sorted(
        path for path in found if not path.is_symlink() and path.is_file() and any(path.is_relative_to(top) for top in tops)
    )
