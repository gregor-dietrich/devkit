#!/usr/bin/env python3
"""Hold a uv project's anchored regex matches to the functions its devkit.toml accepts.

Usage: anchored_match.py COMMAND, for the project at $PROJECT_ROOT (else the working directory):
  check-config  validate devkit.toml's optional [python.anchored-match] table
  run           parse every *.py git lists in the project (tracked, plus untracked ones not ignored)
                except the files [[python.anchored-match.excluded]] names, and fail on every
                anchored .match() or .search() call that no [[python.anchored-match.accepted]]
                entry accepts, on every accepted entry that matches no call any more, and on
                an excluded file git no longer lists
Every failure is one ERROR line on stderr, and run adds one To fix: line; exit 1 (usage: exit 2).

The rule: Python's $ also matches before one trailing newline, so re.match(r"^[a-z]+$", "admin\\n")
passes; re.fullmatch, or \\A...\\Z, do not. A call is flagged when its pattern, a str or bytes
literal (also through a module-level constant bound once, and the literal parts of an f-string),
holds a $ that is neither escaped nor inside [...]. re.search is flagged only when the pattern
also starts with ^ or \\A (which may follow whitespace, global inline flags and group openers), the
validation idiom; flags are ignored. The calls checked are re.match and re.search (also through
import aliases), re.compile(...).match / .search called inline, and NAME.match / .search where
NAME is bound once, in module scope or the enclosing function, to re.compile(...). An entry
accepts a (file, function) pair, the function named as the error line prints it, or <module>;
an excluded entry names one file (a path, no directory or glob) that is neither parsed nor scanned.

The gate is a ratchet, not a proof: it skips every call it cannot resolve (a parameter, an
attribute such as self._RE, a class-level constant, a return value, a name bound twice, a name
imported from another module (each file is read on its own), a symlinked file, a name bound to
re.compile(...).match, the regex module, PurePath.match). A $ in a (?x) or (?#...) comment is a
known false positive (accept it), and an unbalanced [ in one can hide a later $.
A file the interpreter running the gate does not parse fails the run, so none is left unscanned; make
lint runs it under .venv's Python, the project's grammar.
"""

import ast
import os
import platform
import re
import sys
import warnings
from collections import defaultdict
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path
from typing import Any, NamedTuple

# The sibling is found under -I, -P and PYTHONSAFEPATH too, which keep the script directory off sys.path.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from project_files import Failure, python_files, python_table

ROOT: Path = Path(os.environ.get("PROJECT_ROOT", ".")).resolve()
TABLE = "[python.anchored-match] in devkit.toml"
ENTRY = "[[python.anchored-match.accepted]]"
ACCEPTED = f"{ENTRY} in devkit.toml"
EXCLUDED_ENTRY = "[[python.anchored-match.excluded]]"
EXCLUDED = f"{EXCLUDED_ENTRY} in devkit.toml"
KEYS = {"accepted", "excluded"}
ENTRY_KEYS = {"file", "function", "reason"}
EXCLUDED_KEYS = {"file", "reason"}
METHODS = ("match", "search")
HOLE = "\0"  # stands for each {...} of an f-string pattern
# What may precede a search's ^: whitespace, global inline flags, group openers (, (?:, (?P<n>, (?i-s:
LEADING = re.compile(r"(?:\s+|\(\?[aiLmsux]+\)|\((?:\?(?:P<\w+>|[aiLmsux]*(?:-[imsx]+)?:))?)*")
# Each nesting level of the tree costs the walk about two Python frames, and 3.11 builds the tree
# under the same limit; the parser bounds the depth.
DEPTH = 100_000

Key = tuple[str, str]  # a project-relative file, a function qualname
Binding = tuple[str, Any]  # ("import", dotted name), ("value", the assigned expression) or ("other", None)


class Finding(NamedTuple):
    path: str
    line: int
    function: str
    method: str
    pattern: str


class Scope:
    """What one module, function or class body binds: each name's bindings, in any order."""

    def __init__(self, kind: str, parent: "Scope | None") -> None:
        self.kind = kind
        self.parent = parent
        self.bindings: defaultdict[str, list[Binding]] = defaultdict(list)


class Collector(ast.NodeVisitor):
    """Walks one module once, building its scopes and listing its calls with the scope and
    qualname each sits in. A comprehension is part of its enclosing scope; a lambda is a
    function scope named <lambda>."""

    def __init__(self) -> None:
        self.module = self.scope = Scope("module", None)
        self.names: list[str] = []
        self.calls: list[tuple[ast.Call, Scope, str]] = []
        self.declarations: list[tuple[Scope, bool, list[str]]] = []  # (declaring scope, is global, names)

    def bind(self, name: str, binding: Binding = ("other", None)) -> None:
        self.scope.bindings[name].append(binding)

    def inside(self, kind: str, name: str, args: ast.arguments | None, body: list[ast.AST]) -> None:
        outer = self.scope
        self.scope, self.names = Scope(kind, outer), [*self.names, name]
        for arg in (*args.posonlyargs, *args.args, *args.kwonlyargs, args.vararg, args.kwarg) if args else ():
            if arg:
                self.bind(arg.arg)
        for node in body:
            self.visit(node)
        self.scope, self.names = outer, self.names[:-1]

    def visit_function(self, node: ast.FunctionDef | ast.AsyncFunctionDef | ast.Lambda) -> None:
        # Decorators and defaults run in the enclosing scope.
        for part in [*getattr(node, "decorator_list", []), *node.args.defaults, *node.args.kw_defaults]:
            if part:
                self.visit(part)
        if isinstance(node, ast.Lambda):
            self.inside("function", "<lambda>", node.args, [node.body])
        else:
            self.bind(node.name)
            self.inside("function", node.name, node.args, node.body)

    visit_FunctionDef = visit_AsyncFunctionDef = visit_Lambda = visit_function

    def visit_ClassDef(self, node: ast.ClassDef) -> None:
        self.bind(node.name)
        for part in [*node.decorator_list, *node.bases, *(keyword.value for keyword in node.keywords)]:
            self.visit(part)
        self.inside("class", node.name, None, node.body)

    def visit_Name(self, node: ast.Name) -> None:
        if not isinstance(node.ctx, ast.Load):
            self.bind(node.id)

    def visit_Assign(self, node: ast.Assign) -> None:
        for target in node.targets:
            if isinstance(target, ast.Name):
                self.bind(target.id, ("value", node.value))
            else:
                self.visit(target)
        self.visit(node.value)

    def visit_AnnAssign(self, node: ast.AnnAssign) -> None:
        if not isinstance(node.target, ast.Name):
            self.visit(node.target)
        if node.value:
            if isinstance(node.target, ast.Name):
                self.bind(node.target.id, ("value", node.value))
            self.visit(node.value)

    def visit_NamedExpr(self, node: ast.NamedExpr) -> None:
        self.bind(node.target.id, ("value", node.value))
        self.visit(node.value)

    def visit_Import(self, node: ast.Import) -> None:
        for alias in node.names:
            # "import re", "import re._parser" and "import re as r" bind the module; "import os.path" binds "os".
            top = alias.name.partition(".")[0]
            self.bind(alias.asname or top, ("import", "re") if (alias.name if alias.asname else top) == "re" else ("other", None))

    def visit_ImportFrom(self, node: ast.ImportFrom) -> None:
        for alias in node.names:
            known = node.module == "re" and not node.level and alias.name in {*METHODS, "compile"}
            self.bind(alias.asname or alias.name, ("import", f"re.{alias.name}") if known else ("other", None))

    def visit_Global(self, node: ast.Global | ast.Nonlocal) -> None:
        self.declarations.append((self.scope, isinstance(node, ast.Global), node.names))

    visit_Nonlocal = visit_Global

    def resolve_declarations(self) -> None:
        """After the walk: a global or nonlocal statement rebinds the name behind its owner's back, so
        it is not bound "once" there any more, but only when the declaring scope binds it itself. A
        nonlocal also leaves the name unresolvable in the declaring scope."""
        rebound: list[tuple[Scope, str]] = []
        for scope, is_global, names in self.declarations:
            for name in names:
                owner = self.module if is_global else enclosing_function(scope, name)
                rebound += [(scope, name)] if not is_global else []
                rebound += [(owner, name)] if owner and scope is not self.module and name in scope.bindings else []
        for scope, name in rebound:
            scope.bindings[name].append(("other", None))

    def visit_ExceptHandler(self, node: ast.ExceptHandler) -> None:
        if node.name:
            self.bind(node.name)
        self.generic_visit(node)

    def visit_match_capture(self, node: ast.MatchAs | ast.MatchStar | ast.MatchMapping) -> None:
        name = node.rest if isinstance(node, ast.MatchMapping) else node.name
        if name:
            self.bind(name)
        self.generic_visit(node)

    visit_MatchAs = visit_MatchStar = visit_MatchMapping = visit_match_capture

    def visit_Call(self, node: ast.Call) -> None:
        self.calls.append((node, self.scope, ".".join(self.names) or "<module>"))
        self.generic_visit(node)


def enclosing_function(scope: Scope, name: str) -> Scope | None:
    """The nearest function scope around scope that binds name (a class body is skipped), which a
    nonlocal declaration of name in scope rebinds."""
    current = scope.parent
    while current and not (current.kind == "function" and name in current.bindings):
        current = current.parent
    return current


def lookup(name: str, scope: Scope) -> tuple[Scope | None, list[Binding]]:
    """The scope that decides name, and its bindings there; a class body is seen only from itself."""
    current: Scope | None = scope
    while current:
        if (current is scope or current.kind != "class") and name in current.bindings:
            return current, current.bindings[name]
        current = current.parent
    return None, []


def imported(node: ast.expr, scope: Scope) -> str | None:
    """The dotted re name (re, re.match, ...) a Name stands for, if every binding of it imports that."""
    _, found = lookup(node.id, scope) if isinstance(node, ast.Name) else (None, [])
    return found[0][1] if found and found[0][0] == "import" and all(each == found[0] for each in found) else None


def is_re(func: ast.expr, scope: Scope, name: str) -> bool:
    """func is re.NAME, or NAME imported from re."""
    if isinstance(func, ast.Attribute):
        return func.attr == name and imported(func.value, scope) == "re"
    return imported(func, scope) == f"re.{name}"


def pattern_arg(call: ast.Call) -> ast.expr | None:
    if call.args and not isinstance(call.args[0], ast.Starred):
        return call.args[0]
    return next((keyword.value for keyword in call.keywords if keyword.arg == "pattern"), None)


class Target(NamedTuple):
    method: str
    pattern: ast.expr | None
    scope: Scope  # the scope the pattern resolves in


def target(call: ast.Call, scope: Scope) -> Target | None:
    """What call checks, when it is one of the calls the gate checks, else None."""
    func = call.func
    if method := next((name for name in METHODS if is_re(func, scope, name)), None):
        return Target(method, pattern_arg(call), scope)
    if not (isinstance(func, ast.Attribute) and func.attr in METHODS):
        return None
    if isinstance(func.value, ast.Call) and is_re(func.value.func, scope, "compile"):
        return Target(func.attr, pattern_arg(func.value), scope)
    if isinstance(func.value, ast.Name):
        owner, found = lookup(func.value.id, scope)
        if owner and owner.kind != "class" and len(found) == 1 and found[0][0] == "value":
            value = found[0][1]
            if isinstance(value, ast.Call) and is_re(value.func, owner, "compile"):
                return Target(func.attr, pattern_arg(value), owner)
    return None


def literal(node: ast.expr | None, scope: Scope) -> tuple[str, str] | None:
    """(the text to scan, the pattern as shown) for a pattern the gate can resolve, else None.
    An f-string scans as its literal parts, a HOLE for each {...}: a \\ before a hole escapes it."""
    if isinstance(node, ast.Name):
        owner, found = lookup(node.id, scope)
        if not (owner and owner.kind == "module" and len(found) == 1 and found[0][0] == "value"):
            return None
        node = found[0][1]
    match node:
        case ast.Constant(value=str() as text):
            return text, ascii(text)
        case ast.Constant(value=bytes() as raw):
            return raw.decode("latin-1"), ascii(raw)
        case ast.JoinedStr(values=parts):
            text = "".join(part.value if isinstance(part, ast.Constant) else HOLE for part in parts)
            return text, ascii(text.replace(HOLE, "{}"))
    return None


def has_dollar(pattern: str) -> bool:
    """A $ that is not escaped and not inside [...]: a backslash consumes the next character, and
    a class runs to its ] (a ] straight after [ or [^ is a member)."""
    i, in_class = 0, False
    while i < len(pattern):
        char = pattern[i]
        if char == "\\":
            i += 1
        elif in_class:
            in_class = char != "]"
        elif char == "[":
            in_class = True
            i += pattern.startswith("^", i + 1)
            i += pattern.startswith("]", i + 1)  # a ] straight after [ or [^ is a member
        elif char == "$":
            return True
        i += 1
    return False


def anchored(pattern: str, method: str) -> bool:
    rest = pattern[LEADING.match(pattern).end() :]
    return has_dollar(pattern) and (method == "match" or rest.startswith(("^", "\\A")))


@contextmanager
def deep() -> Iterator[None]:
    limit = sys.getrecursionlimit()
    sys.setrecursionlimit(max(limit, DEPTH))
    try:
        yield
    finally:
        sys.setrecursionlimit(limit)


def parse(path: Path) -> ast.Module:
    with warnings.catch_warnings(), deep():  # an invalid escape's SyntaxWarning is ruff's to report
        warnings.simplefilter("ignore")
        return ast.parse(path.read_bytes(), filename=str(path))


def scan(path: Path, tree: ast.Module) -> list[Finding]:
    collector = Collector()
    with deep():
        collector.visit(tree)
    collector.resolve_declarations()
    name = path.relative_to(ROOT).as_posix()
    found = []
    for call, scope, function in collector.calls:
        if not (hit := target(call, scope)) or not (pattern := literal(hit.pattern, hit.scope)):
            continue
        text, shown = pattern
        if anchored(text, hit.method):
            found.append(Finding(name, call.lineno, function, hit.method, shown))
    return found


def accepted_keys(entries: Any) -> set[Key]:
    if not isinstance(entries, list) or not all(isinstance(entry, dict) for entry in entries):
        raise Failure(f"{ACCEPTED} must be an array of tables, each with file, function and a reason.")
    found: set[Key] = set()
    for number, entry in enumerate(entries, 1):
        if stray := sorted(set(entry) - ENTRY_KEYS):
            raise Failure(f"{ACCEPTED} entry {number} sets unknown key(s) {', '.join(stray)}; it reads only file, function and reason.")
        for name, example in (("file", '"src/app/names.py"'), ("function", '"check_name", or "<module>"')):
            value = entry.get(name)
            if not isinstance(value, str) or not value.strip():
                raise Failure(f"{ACCEPTED} entry {number} needs {name} = {example}.")
        key = (os.path.normpath(entry["file"]), entry["function"])
        reason = entry.get("reason")
        if not isinstance(reason, str) or not reason.strip():
            raise Failure(f"{ACCEPTED} entry {number} ({show(key)}) needs a reason saying why the match is safe on a trailing newline.")
        if key in found:
            raise Failure(f"{ACCEPTED} accepts {show(key)} twice; remove one entry.")
        found.add(key)
    return found


def excluded_files(entries: Any) -> set[str]:
    if not isinstance(entries, list) or not all(isinstance(entry, dict) for entry in entries):
        raise Failure(f"{EXCLUDED} must be an array of tables, each with file and a reason.")
    found: set[str] = set()
    for number, entry in enumerate(entries, 1):
        if stray := sorted(set(entry) - EXCLUDED_KEYS):
            raise Failure(f"{EXCLUDED} entry {number} sets unknown key(s) {', '.join(stray)}; it reads only file and reason.")
        value = entry.get("file")
        if not isinstance(value, str) or not value.strip():
            raise Failure(f'{EXCLUDED} entry {number} needs file = "src/fixtures/py2.py".')
        name = os.path.normpath(value)
        reason = entry.get("reason")
        if not isinstance(reason, str) or not reason.strip():
            raise Failure(f"{EXCLUDED} entry {number} ({name}) needs a reason saying why the file is not scanned.")
        if name in found:
            raise Failure(f"{EXCLUDED} excludes {name} twice; remove one entry.")
        found.add(name)
    return found


def show(key: Key) -> str:
    return f"{key[0]} {key[1]}"


def config() -> tuple[set[Key], set[str]]:
    python = python_table(ROOT)
    table = python.get("anchored-match", {}) if isinstance(python, dict) else {}
    if not isinstance(table, dict):
        raise Failure(f"{TABLE} must be a table; it reads only {', '.join(sorted(KEYS))}.")
    if stray := sorted(set(table) - KEYS):
        raise Failure(f"{TABLE} sets unknown key(s) {', '.join(stray)}; it reads only {', '.join(sorted(KEYS))}.")
    accepted, excluded = accepted_keys(table.get("accepted", [])), excluded_files(table.get("excluded", []))
    if both := sorted(key for key in accepted if key[0] in excluded):
        raise Failure(f"{ACCEPTED} accepts {show(both[0])}, a file {EXCLUDED} excludes; remove the accepted entry, an excluded file is not scanned.")
    return accepted, excluded


def check_config() -> str:
    accepted, excluded = config()
    scanned = [path for path in python_files(ROOT, [ROOT]) if path.relative_to(ROOT).as_posix() not in excluded]
    return f"[python.anchored-match]: {len(accepted)} accepted entry(ies), {len(excluded)} excluded file(s); the gate scans the {len(scanned)} Python file(s) git lists."


def run() -> str:
    accepted, excluded = config()
    found: list[Finding] = []
    errors: list[str] = []
    unparsed: set[str] = set()
    listed = {path.relative_to(ROOT).as_posix(): path for path in python_files(ROOT, [ROOT])}
    gone = sorted(excluded - set(listed))
    for name, path in listed.items():
        if name in excluded:
            continue
        try:
            tree = parse(path)
        except (OSError, SyntaxError, ValueError, RecursionError, MemoryError) as exc:
            unparsed.add(name)
            said = (str(exc) or type(exc).__name__).partition("\n")[0]
            errors.append(
                f"ERROR: cannot read {name}: {said}"
                if isinstance(exc, OSError)
                else f"ERROR: cannot parse {name} with Python {platform.python_version()} ({sys.executable}): {type(exc).__name__}: {said}"
            )
        else:
            found += scan(path, tree)
    hits = {(hit.path, hit.function) for hit in found}
    new = [hit for hit in found if (hit.path, hit.function) not in accepted]
    stale = sorted(key for key in accepted - hits if key[0] not in unparsed)
    errors += [
        f"ERROR: anchored .{hit.method}() not accepted in devkit.toml: {hit.path}:{hit.line} in {hit.function}: {hit.pattern}"
        for hit in sorted(new)
    ]
    errors += [f"ERROR: stale {ENTRY} entry, no anchored .match() or .search() in: {show(key)}" for key in stale]
    errors += [f"ERROR: stale {EXCLUDED_ENTRY} entry, git lists no such Python file: {name}" for name in gone]
    if errors:
        remedies = [f"fix the file so that the Python .python-version pins parses it, or exclude it with an {EXCLUDED_ENTRY} entry in devkit.toml (file and a reason)"] if unparsed else []
        remedies += [f"use re.fullmatch (or \\A...\\Z), or accept the function with an {ENTRY} entry in devkit.toml (file, function and a reason)"] if new else []
        remedies += ["remove the stale entries from devkit.toml"] if stale or gone else []
        print("\n".join(errors), file=sys.stderr)
        print(f"To fix: {'; '.join(remedies)}.", file=sys.stderr)
        sys.exit(1)
    return f"anchored-match: no anchored .match() or .search() beyond the {len(accepted)} accepted function(s)."


def main() -> None:
    try:
        match sys.argv[1:]:
            case ["check-config"]:
                print(check_config())
            case ["run"]:
                print(run())
            case _:
                print("usage: anchored_match.py {check-config|run}", file=sys.stderr)
                sys.exit(2)
    except Failure as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
