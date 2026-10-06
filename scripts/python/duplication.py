#!/usr/bin/env python3
"""Hold a uv project's copy-paste duplication to the file pairs its devkit.toml accepts.

Usage: duplication.py COMMAND, for the project at $PROJECT_ROOT (else the working directory):
  check-config  validate devkit.toml's [python.duplication] table and list the Python files
                git lists (tracked, plus untracked ones not ignored) under its paths
  run JSCPD     validate it, run JSCPD (the jscpd of devkit's closure) on devkit's detector
                controls, then on those files; fail on every file pair jscpd reports a clone
                of that no [[python.duplication.accepted]] entry accepts, and on every
                accepted pair it no longer reports
Every failure is one ERROR line on stderr (a clone adds the lines jscpd reported); exit 1.
"""

import errno
import json
import os
import signal
import subprocess
import sys
import tempfile
import tomllib
from pathlib import Path
from typing import Any, NamedTuple

ROOT: Path = Path(os.environ.get("PROJECT_ROOT", ".")).resolve()
CONTROLS: Path = Path(__file__).resolve().parents[2] / "jscpd" / "controls"
CONTROL_PAIR = ("duplicate_a.py", "duplicate_b.py")
TABLE = "[python.duplication] in devkit.toml"
ENTRY = "[[python.duplication.accepted]]"
ACCEPTED = f"{ENTRY} in devkit.toml"
KEYS = {"paths", "min-tokens", "ignore", "accepted"}
ENTRY_KEYS = {"files", "reason"}
DEFAULT_MIN_TOKENS = 50
# Upper bound for one jscpd run.
TIMEOUT = 600

Pair = tuple[str, str]


class Failure(Exception):
    """A check that failed; its message is the ERROR line."""


class Config(NamedTuple):
    paths: list[Path]
    files: list[Path]
    min_tokens: int
    ignore: list[str]
    accepted: set[Pair]


def pair(first: str, second: str) -> Pair:
    """The key of a clone or an accepted entry: its two project-relative files, sorted."""
    a, b = sorted(os.path.normpath(name) for name in (first, second))
    return a, b


def show(key: Pair) -> str:
    return f"{key[0]}  ~  {key[1]}"


def is_strings(value: Any) -> bool:
    return isinstance(value, list) and all(isinstance(item, str) and item for item in value)


def project_path(name: str) -> Path:
    path = (ROOT / name).resolve()
    if Path(name).is_absolute():
        raise Failure(f"{TABLE} lists the absolute path {name} in paths; give it relative to the project root.")
    if not path.is_relative_to(ROOT):
        raise Failure(f"{TABLE} lists {name} in paths, which leaves the project root; list paths inside it.")
    if not path.exists():
        raise Failure(f"{TABLE} lists {name} in paths, which does not exist; fix or remove it.")
    return path


def accepted_pairs(entries: Any) -> set[Pair]:
    if not isinstance(entries, list) or not all(isinstance(entry, dict) for entry in entries):
        raise Failure(f"{ACCEPTED} must be an array of tables, each with files and a reason.")
    found: set[Pair] = set()
    for number, entry in enumerate(entries, 1):
        if stray := sorted(set(entry) - ENTRY_KEYS):
            raise Failure(f"{ACCEPTED} entry {number} sets unknown key(s) {', '.join(stray)}; it reads only files and reason.")
        files = entry.get("files")
        if not is_strings(files) or len(files) != 2:
            raise Failure(
                f"{ACCEPTED} entry {number} needs files = [<path>, <path>], two project-relative files "
                "(the same one twice for a clone within one file)."
            )
        key = pair(*files)
        reason = entry.get("reason")
        if not isinstance(reason, str) or not reason.strip():
            raise Failure(f"{ACCEPTED} entry {number} ({show(key)}) needs a reason saying why the duplication is deliberate.")
        if key in found:
            raise Failure(f"{ACCEPTED} accepts {show(key)} twice; remove one entry.")
        found.add(key)
    return found


def python_files(paths: list[Path]) -> list[Path]:
    """The *.py files git lists (tracked, plus untracked ones the project does not ignore) under
    paths, each once; a tracked file deleted from disk, and a symlink, are skipped.

    jscpd gets them as file arguments: a directory argument would let its walker apply the
    .ignore files in and above the project, and skip tracked files that .gitignore matches.
    The user's global excludes (core.excludesFile) do not apply.
    """
    command = ["git", "-c", "core.excludesFile=/dev/null", "ls-files", "-z", "--cached", "--others", "--exclude-standard"]
    try:
        listed = subprocess.run(command, cwd=ROOT, capture_output=True, check=False)
    except OSError as exc:
        raise Failure(f"git cannot list the files in {ROOT}: {exc}") from exc
    if listed.returncode != 0:
        said = os.fsdecode(listed.stderr).strip().partition("\n")[0]
        raise Failure(f"git cannot list the files in {ROOT}: {said or f'exit {listed.returncode}'}")
    found = {ROOT / os.fsdecode(name) for name in listed.stdout.split(b"\0") if name.endswith(b".py")}
    return sorted(
        path for path in found if not path.is_symlink() and path.is_file() and any(path.is_relative_to(top) for top in paths)
    )


def config() -> Config:
    try:
        with (ROOT / "devkit.toml").open("rb") as handle:
            python = tomllib.load(handle).get("python")
    except FileNotFoundError as exc:
        raise Failure(f"no devkit.toml in {ROOT}.") from exc
    except (OSError, ValueError) as exc:  # TOMLDecodeError subclasses ValueError
        raise Failure(f"cannot read devkit.toml: {exc}") from exc
    table = python.get("duplication") if isinstance(python, dict) else None
    example = 'e.g. paths = ["src", "tests"]'
    if not isinstance(table, dict):
        raise Failure(f"devkit.toml has no [python.duplication] table; add one whose paths lists what jscpd scans, {example}.")
    if stray := sorted(set(table) - KEYS):
        raise Failure(f"{TABLE} sets unknown key(s) {', '.join(stray)}; it reads only {', '.join(sorted(KEYS))}.")
    if "paths" not in table:
        raise Failure(f"{TABLE} sets no paths; list the project directories or files jscpd scans, {example}.")
    if not is_strings(table["paths"]) or not table["paths"]:
        raise Failure(f"{TABLE}: paths must be a non-empty list of project-relative paths, {example}.")
    min_tokens = table.get("min-tokens", DEFAULT_MIN_TOKENS)
    if isinstance(min_tokens, bool) or not isinstance(min_tokens, int) or min_tokens < 1:
        raise Failure(f"{TABLE}: min-tokens must be a positive integer (default {DEFAULT_MIN_TOKENS}), not {min_tokens!r}.")
    ignore = table.get("ignore", [])
    if not is_strings(ignore):
        raise Failure(f'{TABLE}: ignore must be a list of jscpd glob patterns, e.g. ignore = ["**/migrations/**"].')
    if comma := next((glob for glob in ignore if "," in glob), None):
        raise Failure(f"{TABLE}: ignore pattern {comma} holds a comma, which jscpd splits on; list each glob on its own.")
    paths = [project_path(name) for name in table["paths"]]
    accepted = accepted_pairs(table.get("accepted", []))
    if not (files := python_files(paths)):
        listed = ", ".join(table["paths"])
        raise Failure(f"git lists no Python files under {TABLE}'s paths ({listed}); list the directories holding them.")
    return Config(paths, files, min_tokens, ignore, accepted)


def scan(jscpd: str, files: list[Path], min_tokens: int, ignore: list[str]) -> list[dict[str, Any]]:
    """The clones jscpd reports among files, run with every setting explicit.

    It runs in an empty directory with an empty HOME: jscpd reads .jscpd.json and package.json
    from its working directory, and the user's git excludes from HOME and XDG_CONFIG_HOME;
    without NODE_PATH and NODE_OPTIONS its Node.js shim resolves the platform binary inside
    the closure only.
    """
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)
        (work / "cwd").mkdir()
        (work / "home").mkdir()
        output = work / "report"
        command = [jscpd, "--min-tokens", str(min_tokens), "--format", "python", "--absolute"]
        command += ["--reporters", "json", "--output", str(output)]
        command += [f"--ignore={glob}" for glob in ignore] + [str(path) for path in files]
        env = {name: value for name, value in os.environ.items() if name not in {"XDG_CONFIG_HOME", "NODE_PATH", "NODE_OPTIONS"}}
        run_jscpd(command, work / "cwd", env | {"HOME": str(work / "home")})
        try:
            report = json.loads((output / "jscpd-report.json").read_text(encoding="utf-8"))
        except FileNotFoundError as exc:
            raise Failure("jscpd wrote no report, so its clones are unknown; its output format changed under devkit.") from exc
        except ValueError as exc:  # JSONDecodeError and UnicodeDecodeError both subclass it
            raise Failure(f"cannot read jscpd's report: {exc}") from exc
    clones = report.get("duplicates") if isinstance(report, dict) else None
    if not isinstance(clones, list) or not all(isinstance(clone, dict) for clone in clones):
        raise Failure("jscpd's report holds no list of duplicates; its format changed under devkit.")
    return clones


def run_jscpd(command: list[str], cwd: Path, env: dict[str, str]) -> None:
    """Run jscpd in a process group of its own, which a timeout kills whole: its Node.js shim
    runs the platform binary as a child."""
    try:
        process = subprocess.Popen(
            command, cwd=cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, start_new_session=True
        )
    except OSError as exc:
        # The files are its arguments: beyond the system's limit (ARG_MAX, some 2 MB on Linux) exec fails.
        too_long = " (too many files for one command line; narrow paths)" if exc.errno == errno.E2BIG else ""
        raise Failure(f"cannot run jscpd{too_long}: {exc}") from exc
    try:
        said = process.communicate(timeout=TIMEOUT)[0]
    except subprocess.TimeoutExpired as exc:
        raise Failure(f"jscpd did not finish within {TIMEOUT} seconds; it was killed.") from exc
    finally:
        if process.returncode is None:  # timed out, or interrupted
            os.killpg(process.pid, signal.SIGKILL)
            process.communicate()
    if process.returncode != 0:
        said = said.strip().replace("\n", "\n    ") or "nothing"
        raise Failure(f"jscpd failed (exit {process.returncode}). It reported:\n    {said}")


def by_pair(clones: list[dict[str, Any]], root: Path) -> dict[Pair, list[str]]:
    """Each file pair jscpd reports a clone of, relative to root, with one line per clone."""
    found: dict[Pair, list[str]] = {}
    for clone in clones:
        try:
            first, second = clone["firstFile"], clone["secondFile"]
            key = pair(os.path.relpath(first["name"], root), os.path.relpath(second["name"], root))
            where = [f"{os.path.relpath(f['name'], root)}:{f['start']}-{f['end']}" for f in (first, second)]
        except (KeyError, TypeError) as exc:
            raise Failure(f"jscpd's report has a clone without its files ({exc!r}); its format changed under devkit.") from exc
        found.setdefault(key, []).append(f"    {where[0]} and {where[1]} ({clone.get('tokens')} tokens)")
    return found


def control(jscpd: str) -> None:
    """jscpd must find the one clone among devkit's controls, or a passing run would prove nothing."""
    found = by_pair(scan(jscpd, sorted(CONTROLS.glob("*.py")), DEFAULT_MIN_TOKENS, []), CONTROLS)
    if list(found) != [CONTROL_PAIR]:
        reported = ", ".join(show(key) for key in found) or "no clone"
        raise Failure(f"jscpd's detector control failed: it reported {reported}, not exactly {show(CONTROL_PAIR)} in {CONTROLS}.")


def check_config() -> str:
    settings = config()
    paths = ", ".join(str(path.relative_to(ROOT)) for path in settings.paths)
    return f"[python.duplication]: jscpd scans the {len(settings.files)} Python file(s) git lists under {paths}."


def run(jscpd: str) -> str:
    settings = config()
    control(jscpd)
    found = by_pair(scan(jscpd, settings.files, settings.min_tokens, settings.ignore), ROOT)
    new = sorted(set(found) - settings.accepted)
    stale = sorted(settings.accepted - set(found))
    errors = [f"ERROR: duplicated code not accepted in devkit.toml: {show(key)}\n" + "\n".join(found[key]) for key in new]
    errors += [f"ERROR: stale {ENTRY} entry, no longer duplicated: {show(key)}" for key in stale]
    if errors:
        accept = f"extract the shared code, or accept the pair with an {ENTRY} entry in devkit.toml (files and a reason)"
        remedies = ([accept] if new else []) + (["remove the stale entries from devkit.toml"] if stale else [])
        print("\n".join(errors), file=sys.stderr)
        print(f"To fix: {'; '.join(remedies)}.", file=sys.stderr)
        sys.exit(1)
    return f"jscpd: no duplicated code beyond the {len(settings.accepted)} accepted file pair(s)."


def main() -> None:
    try:
        match sys.argv[1:]:
            case ["check-config"]:
                print(check_config())
            case ["run", jscpd]:
                print(run(jscpd))
            case _:
                print("usage: duplication.py {check-config|run JSCPD}", file=sys.stderr)
                sys.exit(2)
    except Failure as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
