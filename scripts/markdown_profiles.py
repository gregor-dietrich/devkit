#!/usr/bin/env python3
"""Group the Markdown files lint-md checks by the markdownlint configuration each uses.

`make lint-md` and `make format-md` run this in $PROJECT_ROOT with the default
configuration as the one argument and the NUL-separated file list on stdin, reading
devkit.toml's optional `[markdown.profiles]` as docs/contract.md describes: a table of
`"<subtree>" = "<config>.jsonc"`. A file belongs to the profile with the longest subtree
that holds it, else to the default configuration.

Prints, per non-empty group (the default first, then the profiles by subtree), the
configuration, its files and an empty field, each NUL-terminated. Exits 1 with one
ERROR line on a devkit.toml error, among them a subtree that holds no listed file.
"""

import os
import posixpath
import sys
import tomllib
from pathlib import Path


def load_profiles(toml_path: Path) -> dict[str, str]:
    """The `[markdown.profiles]` table as {subtree: config}; empty when the file or table
    is absent.

    Raises ValueError, naming devkit.toml, on invalid TOML, a key under [markdown] but
    profiles, a profiles value that is not a table, a subtree or config that is not a
    relative, normalized path inside the project, a config that is not a `.jsonc`
    file there.
    """
    name = toml_path.name
    if not toml_path.is_file():
        return {}
    try:
        with toml_path.open("rb") as handle:
            markdown = tomllib.load(handle).get("markdown", {})
    except (OSError, ValueError) as exc:  # TOMLDecodeError subclasses ValueError
        raise ValueError(f"cannot read {name}: {exc}") from exc
    if not isinstance(markdown, dict):
        raise ValueError(f"{name}: markdown must be the table [markdown]")
    if stray := sorted(set(markdown) - {"profiles"}):
        raise ValueError(f"{name}: unknown key(s) under [markdown]: {', '.join(stray)}; only profiles is read")
    profiles = markdown.get("profiles", {})
    if not isinstance(profiles, dict):
        raise ValueError(f"{name}: markdown.profiles must be the table [markdown.profiles]")
    for subtree, config in profiles.items():
        for what, path in (("subtree", subtree), ("config", config)):
            if not (
                isinstance(path, str)
                and path != "."
                and posixpath.normpath(path) == path
                and not path.startswith("/")
                and ".." not in path.split("/")
                and "\0" not in path
            ):
                hint = "; quote a subtree that holds a dot" if isinstance(path, dict) else ""
                raise ValueError(
                    f"{name}: [markdown.profiles] {what} {path!r} is not a relative, normalized path inside the project{hint}"
                )
        if not (config.endswith(".jsonc") and (toml_path.parent / config).is_file()):
            raise ValueError(f"{name}: [markdown.profiles] config {config!r} is not a .jsonc file in the project")
    return profiles


def group_files(default: str, files: list[str], profiles: dict[str, str]) -> list[tuple[str, list[str]]]:
    """[(config, files)] for the non-empty groups, the default first, then the profiles by
    subtree; each file goes under its longest matching subtree. Raises ValueError for a
    subtree that holds no file, which a typo would otherwise send to the default."""
    held: dict[str | None, list[str]] = {subtree: [] for subtree in [None, *sorted(profiles)]}
    for file in files:
        subtrees = [subtree for subtree in held if subtree and file.startswith(subtree + "/")]
        held[max(subtrees, key=len, default=None)].append(file)
    for subtree, group in held.items():
        if subtree and not group:
            raise ValueError(f"devkit.toml: [markdown.profiles] subtree {subtree!r} holds no Markdown file lint-md checks (symlinks and deleted files are skipped)")
    return [(profiles[subtree] if subtree else default, group) for subtree, group in held.items() if group]


def main() -> None:
    # File names as bytes both ways: os.fsdecode/os.fsencode round-trip a name that is not UTF-8.
    files = [os.fsdecode(raw) for raw in sys.stdin.buffer.read().split(b"\0") if raw]
    try:
        groups = group_files(sys.argv[1], files, load_profiles(Path("devkit.toml")))
    except (OSError, ValueError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(1)
    for config, group in groups:
        sys.stdout.buffer.write(b"".join(os.fsencode(field) + b"\0" for field in (config, *group, "")))


if __name__ == "__main__":
    main()
