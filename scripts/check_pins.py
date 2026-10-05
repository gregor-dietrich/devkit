#!/usr/bin/env python3
"""Check that every workflow action and container image the project names is pinned.

`make lint-pins` runs this over the files git lists in $PROJECT_ROOT (tracked, plus
untracked files that are not ignored), as docs/contract.md describes:

- an action (`uses:` in a workflow or an action.y{a,}ml) must be
  `owner/repo[/path]@<40 lowercase hex>` followed by the comment `# vX.Y.Z`;
- an image (Dockerfile `FROM`, `COPY --from=` and `# syntax=`, YAML `image:`,
  `container:` and service values, `docker://`) must be
  `<repository>:<tag>@sha256:<64 hex>`.

A tag or branch can move under the same name, so only a digest or a full commit SHA
names fixed content; the tag or version comment beside it says which release that
content is meant to be, so an update can be checked against it. Exempt: Dockerfile
build stages, `scratch`, images under a namespace devkit.toml lists in
`[pins] first-party`, `./` actions whose action file git lists (it is read itself),
and a Docker container action's relative Dockerfile that git lists (read itself). A line
or reference the readers below cannot read fails rather than being skipped. The
readers are line-based, not YAML or Dockerfile parsers (stdlib only), and each one's
limits are in its docstring.

Prints a census line on stdout and one line per violation on stderr; exits 1 on any
violation, and on a devkit.toml or git error, which is one ERROR line.
"""

import os
import posixpath
import re
import subprocess
import sys
import tomllib
from collections.abc import Iterator
from dataclasses import dataclass
from pathlib import Path

# --- image references ------------------------------------------------------
#
# The grammar the Docker CLI and BuildKit share: an optional registry host with an
# optional port, then lowercase path components; a tag of at most 128 word
# characters, dots and dashes; and a sha256 digest. Validators: every use is
# .fullmatch on these unanchored patterns.
_IMAGE_DOMAIN = (
    r"[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?"
    r"(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)*"
    r"(?::[0-9]+)?"
)
_IMAGE_PATH_COMPONENT = r"[a-z0-9]+(?:(?:[._]|__|-+)[a-z0-9]+)*"
_IMAGE_NAME_RE = re.compile(rf"(?:{_IMAGE_DOMAIN}/)?{_IMAGE_PATH_COMPONENT}(?:/{_IMAGE_PATH_COMPONENT})*")
_IMAGE_TAG_RE = re.compile(r"[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}")
_IMAGE_DIGEST_RE = re.compile(r"sha256:[0-9a-f]{64}")
# Docker Hub's two spellings of itself; index.docker.io is the legacy one.
_DOCKER_HUB_PREFIXES = ("docker.io/", "index.docker.io/")
_DOCKER_HUB_OFFICIAL = "library/"
# A first path component names a registry host when it holds a "." or a ":", or is
# "localhost". Only the host is case-insensitive; the path is not.
_REGISTRY_HOST_MARKS = (".", ":")
_REGISTRY_LOCALHOST = "localhost"


@dataclass(frozen=True)
class ImageRef:
    """An image reference as Docker resolves it: `repository[:tag][@digest]`.

    `repository` is the familiar name (familiar_repository); `digest` keeps its
    `sha256:` prefix.
    """

    repository: str
    tag: str | None
    digest: str | None


@dataclass(frozen=True)
class Violation:
    file: str
    line: int
    message: str

    def __str__(self) -> str:
        return f"{self.file}:{self.line}: {self.message}"


class Failure(Exception):
    """A failure that stops the check before any file is read; its message is the ERROR line."""


def _split_image_tag(name: str) -> tuple[str, str | None]:
    """`repo[:tag]` -> (repo, tag). Only the last path component carries a tag, so a
    registry `host:port/` prefix is never read as one."""
    head, slash, last = name.rpartition("/")
    base, colon, tag = last.partition(":")
    return (head + slash + base, tag) if colon else (name, None)


def _is_registry_host(component: str) -> bool:
    return any(mark in component for mark in _REGISTRY_HOST_MARKS) or component.lower() == _REGISTRY_LOCALHOST


def familiar_repository(name: str) -> str:
    """Collapse Docker Hub's spellings to the name `docker images` shows.

    `docker.io/library/python`, `docker.io/python`, `index.docker.io/library/python`
    and `library/python` are all `python`; `docker.io/org/name` is `org/name`. A
    registry host is lowercased (`GHCR.IO/org/app` is `ghcr.io/org/app`). Another
    registry, or a `library/` path deeper than one component, is left as written: a
    mirror is another name. The Docker Hub prefix is kept when what follows it opens
    with a host itself: `docker.io/ghcr.io/org/app` is a Docker Hub path, not ghcr.io's
    image, and collapsing it would let it pass as ghcr.io's, or as first-party.
    """
    host, slash, path = name.partition("/")
    if slash and _is_registry_host(host):
        name = host.lower() + slash + path
    for prefix in _DOCKER_HUB_PREFIXES:
        if name.startswith(prefix):
            rest = name.removeprefix(prefix)
            inner, inner_slash, _ = rest.partition("/")
            if not (inner_slash and _is_registry_host(inner)):
                name = rest
            break
    rest = name.removeprefix(_DOCKER_HUB_OFFICIAL)
    return rest if rest != name and "/" not in rest else name


def parse_image_reference(token: str) -> ImageRef | None:
    """Read `repo[:tag][@sha256:<64 hex>]`, or None for every shape Docker would reject
    or this reader cannot vouch for: a build variable, quotes, an uppercase path, a
    malformed tag, a short or non-sha256 digest."""
    name, at, digest = token.partition("@")
    if at and _IMAGE_DIGEST_RE.fullmatch(digest) is None:
        return None
    repository, tag = _split_image_tag(name)
    if tag is not None and _IMAGE_TAG_RE.fullmatch(tag) is None:
        return None
    if _IMAGE_NAME_RE.fullmatch(repository) is None:
        return None
    return ImageRef(familiar_repository(repository), tag, digest if at else None)


def _is_first_party(token: str, first_party: tuple[str, ...]) -> bool:
    """Whether the repository part of *token* lies under a first-party namespace.

    Split loosely, before the full parse, so a first-party image whose tag the release
    tooling fills in (`acme/app:${REVISION:-1}`) is exempt; a repository part that is
    not a well-formed name (a variable in it) is never first-party.
    """
    repository = _split_image_tag(token.partition("@")[0])[0]
    if _IMAGE_NAME_RE.fullmatch(repository) is None:
        return False
    familiar = familiar_repository(repository)
    return any(familiar.startswith(f"{familiar_repository(ns)}/") for ns in first_party)


def _image_message(token: str, first_party: tuple[str, ...]) -> str | None:
    """The violation message for one image reference, or None if it passes."""
    if _is_first_party(token, first_party):
        return None
    ref = parse_image_reference(token)
    if ref is None:
        return (
            f"image reference {token!r} does not parse as '<repository>:<tag>@sha256:<64 hex>': "
            "a build variable, a template expression or odd quoting hides which image runs, "
            "so its pin cannot be checked; write the reference out"
        )
    absent = [name for name, value in (("tag", ref.tag), ("digest", ref.digest)) if value is None]
    if not absent:
        return None
    return (
        f"image reference {token!r} is not pinned as '{ref.repository}:<tag>@sha256:<64 hex>': "
        f"it carries no {' or '.join(absent)}; a tag can be pushed again with other content, so "
        "only the digest fixes what runs, and the tag beside it names the release the digest is "
        "checked against"
    )




# --- Dockerfiles -----------------------------------------------------------
#
# A Dockerfile's basename, case-insensitive: dockerfile or containerfile alone or
# followed by ".", "-" or "_" and a suffix, or ending in .dockerfile or .containerfile.
# The ignore files beside them are not Dockerfiles.
_DOCKERFILE_NAME_RE = re.compile(r"(?:docker|container)file(?:[._-].*)?|.*\.(?:docker|container)file", re.I | re.S)
_DOCKER_IGNORE_RE = re.compile(r".*\.(?:docker|container)ignore", re.I | re.S)
# The instructions of the Dockerfile syntax. A first word outside them is another
# frontend's syntax (`// syntax=`, JSON) or a heredoc body: unreadable.
_INSTRUCTIONS = frozenset(
    {
        "add", "arg", "cmd", "copy", "entrypoint", "env", "expose", "from", "healthcheck",
        "label", "maintainer", "onbuild", "run", "shell", "stopsignal", "user", "volume", "workdir",
    }
)  # fmt: skip
# A FROM option, in the documented --flag=value form only; a bare --flag is a line
# this reader does not read.
_FROM_OPTION_RE = re.compile(r"--[A-Za-z][A-Za-z0-9-]*=\S*")
# A build stage name as BuildKit accepts it, compared lowercased.
_STAGE_NAME_RE = re.compile(r"[a-z][a-z0-9_.-]*")
# COPY --from=<n> addresses a stage by index.
_STAGE_INDEX_RE = re.compile(r"[0-9]+")
# A build source named anywhere on a logical line: --from=, and the from= key of
# RUN --mount=type=bind,from=..., with a quote on either side of the key, which
# BuildKit strips. A scan: .search.
_BUILD_SOURCE_RE = re.compile(r"(?:--|[=,])[\"']?from[\"']?=", re.IGNORECASE)
# BuildKit's line model: lines split on "\n" alone (one trailing "\r" dropped), and a
# line continues when it ends in the escape character plus spaces and tabs only. A
# no-break space or a form feed after the "\" ends no continuation, which
# str.splitlines() and rstrip() would get wrong. A scan: .search.
_CONTINUATION_RE = re.compile(r"\\[ \t]*$")
# A parser-directive-shaped line, `# name=value`, read after its leading whitespace
# is stripped. BuildKit reads directives only in the file's leading block (after an
# optional `#!` line) and stops at the first line that is not one; this is a superset
# of its pattern, so its block is never longer than this one. A validator: .fullmatch.
_PARSER_DIRECTIVE_RE = re.compile(r"#\s*([A-Za-z][A-Za-z0-9_-]*)\s*=(.*)")
_SHEBANG = "#!"
# `# syntax=` names the frontend image that parses the file: an image reference.
_SYNTAX_DIRECTIVE = "syntax"
# `# escape=` moves the continuation character this reader models: unreadable.
_ESCAPE_DIRECTIVE = "escape"
# The instructions that can open a heredoc, whose bodies this reader does not parse.
_HEREDOC_INSTRUCTIONS = frozenset({"add", "copy", "onbuild", "run"})
_HEREDOC_MARK = "<<"

_FROM = "from"
_COPY_FROM = "copy-from"
_SYNTAX = "syntax"
_UNCLASSIFIED = "unclassified"


def is_dockerfile(path: str) -> bool:
    """Whether a path's basename names a Dockerfile (_DOCKERFILE_NAME_RE)."""
    name = path.rpartition("/")[2]
    return _DOCKERFILE_NAME_RE.fullmatch(name) is not None and _DOCKER_IGNORE_RE.fullmatch(name) is None


def _read_from_arguments(args: list[str]) -> tuple[str, str | None] | None:
    """`FROM [--opt=v]... <image> [AS <stage>]` -> (image, stage, lowercased), or None
    for any other shape: no image, a bare --flag, trailing words, a stage name
    BuildKit rejects."""
    index = 0
    while index < len(args) and args[index].startswith("--"):
        if _FROM_OPTION_RE.fullmatch(args[index]) is None:
            return None
        index += 1
    rest = args[index:]
    if len(rest) == 1:
        return rest[0], None
    if len(rest) == 3 and rest[1].lower() == "as" and _STAGE_NAME_RE.fullmatch(rest[2].lower()):
        return rest[0], rest[2].lower()
    return None


def _copy_source(args: list[str]) -> str | None:
    """The --from= value among a COPY's leading options, if any."""
    for word in args:
        if not word.startswith("--"):
            break
        name, _, value = word.partition("=")
        if name.lower() == "--from":
            return value
    return None


def _is_dead(line: str) -> bool:
    """A blank or comment line: dead, and inside a continuation dropped."""
    words = line.split()
    return not words or words[0].startswith("#")


def _logical_lines(lines: list[str], start: int) -> Iterator[tuple[int, str, bool]]:
    """(opening line number, logical line, whether it spans physical lines), joined as
    BuildKit joins them: the escape character and the blanks after it removed, dead
    lines inside the continuation dropped, the next line appended with no separator."""
    index = start
    while index < len(lines):
        lineno, joined, spans = index + 1, lines[index], False
        index += 1
        if _is_dead(joined):
            continue
        while _CONTINUATION_RE.search(joined) is not None:
            joined = _CONTINUATION_RE.sub("", joined)
            while index < len(lines) and _is_dead(lines[index]):
                index += 1
            if index == len(lines):
                break
            joined, spans = joined + lines[index], True
            index += 1
        yield lineno, joined, spans


def dockerfile_references(text: str) -> Iterator[tuple[int, str, str]]:
    """Every live image-reference site in a Dockerfile, its token unparsed.

    Yields (lineno, kind, token): kind "from", "copy-from" or "syntax" with the raw
    reference, or "unclassified" with the stripped logical line for one this reader
    cannot read. Stage references (an earlier `AS <name>`, compared case-insensitively,
    or a numeric `--from=<n>`) and `FROM scratch` are skipped.

    A leading BOM is removed, and a `#!` first line is skipped with the directive block
    still open. After the directive block, instructions are read as logical lines
    (_logical_lines), each reported at its opening line. Unclassified, so failing: an
    `# escape=` directive; a logical line whose first word is not an instruction
    (_INSTRUCTIONS), which also fails each line of a heredoc body and a logical line
    left empty by a lone "\\" at the end of the file; a FROM the reader
    cannot place, or that spans physical lines; a `COPY --from=` value holding a "\\";
    any "<<" in an instruction that can open a heredoc (a shell "<<<" too: a false
    positive, but a closed one); any other logical line naming a `from=` build source.
    """
    lines = [line.removesuffix("\r") for line in text.removeprefix("\ufeff").split("\n")]
    index = 1 if lines[0].startswith(_SHEBANG) else 0
    while index < len(lines) and (directive := _PARSER_DIRECTIVE_RE.fullmatch(lines[index].strip())):
        name = directive.group(1).lower()
        if name == _SYNTAX_DIRECTIVE:
            yield index + 1, _SYNTAX, directive.group(2).strip()
        elif name == _ESCAPE_DIRECTIVE:
            yield index + 1, _UNCLASSIFIED, lines[index].strip()
        index += 1
    stages: set[str] = set()
    for lineno, line, spans in _logical_lines(lines, index):
        words = line.split()
        instruction = words[0].lower() if words else ""
        heredoc = instruction in _HEREDOC_INSTRUCTIONS and _HEREDOC_MARK in line
        if instruction not in _INSTRUCTIONS or heredoc:
            yield lineno, _UNCLASSIFIED, line.strip()
            continue
        if instruction == "from":
            read = None if spans else _read_from_arguments(words[1:])
            if read is None:
                yield lineno, _UNCLASSIFIED, line.strip()
                continue
            token, stage = read
            if token.lower() not in stages | {"scratch"}:
                yield lineno, _FROM, token
            if stage is not None:
                stages.add(stage)
            continue
        source = _copy_source(words[1:]) if instruction == "copy" else None
        if source is not None:
            if "\\" in source:
                yield lineno, _UNCLASSIFIED, line.strip()
            elif source.lower() not in stages and _STAGE_INDEX_RE.fullmatch(source) is None:
                yield lineno, _COPY_FROM, source
            continue
        if _BUILD_SOURCE_RE.search(line) is not None:
            yield lineno, _UNCLASSIFIED, line.strip()


def _dockerfile_messages(text: str, first_party: tuple[str, ...]) -> Iterator[tuple[int, str]]:
    for lineno, kind, token in dockerfile_references(text):
        if kind == _UNCLASSIFIED:
            message: str | None = (
                f"live line {token!r} is in a shape this check cannot read (a first word that is "
                "not a Dockerfile instruction, such as another frontend's syntax or a heredoc body; "
                "a FROM with a bare --flag, extra words or a continued line; a heredoc; a build "
                "source other than a plain COPY --from=; an escape= parser directive), so an image "
                "named there would escape the pin check; write the reference on one plain line"
            )
        else:
            message = _image_message(token, first_party)
        if message is not None:
            yield lineno, message


# --- YAML: workflows, composite actions, compose files ----------------------
#
# YAML 1.2's line breaks, and no others: str.splitlines would also split on a form
# feed or a file separator, which a YAML parser rejects rather than breaks on.
_YAML_LINE_BREAK_RE = re.compile(r"\r\n|\r|\n")
# YAML 1.1's further breaks (NEL, LINE SEPARATOR, PARAGRAPH SEPARATOR). YAML 1.2 made
# them content, but YAML 1.1 parsers still break on them, and a key after one would
# sit on a line this reader never sees. A line holding one fails. A scan: .search.
_YAML_FOREIGN_BREAK_RE = re.compile("[\u0085\u2028\u2029]")
# The keys read. `container` in its scalar form is the job image; its mapping form's
# `image:` child is read as an `image` key. `dockerfile` names the Dockerfile a compose
# build reads, which must be a file the Dockerfile family reads. `dockerfile_inline` is
# a compose build key whose FROM nothing reads, so it fails in every shape.
_YAML_PIN_KEYS = "uses|image|container|dockerfile_inline|dockerfile"
# A key spelled so this reader cannot vouch for it: node properties before it (&anchor,
# !tag, !!str), or a double-quoted key holding an escape ("u\x73es" is uses).
_YAML_KEY_PROPERTIES = r"(?:[&!][^ \t]*[ \t]+)*"
_YAML_ESCAPED_KEY = r'"(?:[^"\\]*\\.)+[^"\\]*"'
# One of those keys anywhere a key can start on a line: at its start (after indent
# and any "-"), or after a flow opener or separator; quoted or not, spaced before the
# colon or not, behind node properties, escaped, or as an explicit `? key`. Keys, not
# substrings: `run: echo "image: x"` holds none. A scan: .search.
_YAML_PIN_KEY_RE = re.compile(
    r"(?:^|[{\[,])[ \t]*(?:-[ \t]*)*(?:"
    rf"{_YAML_KEY_PROPERTIES}"
    rf"(?:([\"']?)(?:{_YAML_PIN_KEYS})\1|{_YAML_ESCAPED_KEY})[ \t]*:"
    rf"|\?[ \t]+{_YAML_KEY_PROPERTIES}"
    rf"(?:([\"']?)(?:{_YAML_PIN_KEYS})\2|{_YAML_ESCAPED_KEY})(?:[ \t:]|$)"
    r")"
)
# Key positions whose key this reader cannot name: an explicit-key "?" or a value ":"
# indicator, an alias used as a key, a tagged key. Any of them, whatever key it
# spells, is unreadable. A scan: .search.
_YAML_ODD_KEY_RE = re.compile(
    r"(?:^|[{\[,])[ \t]*(?:-[ \t]+)*"
    r"(?:[?:](?:[ \t]|$)|\*[^ \t]+[ \t]*:|![^ \t]*[ \t]+[^ \t#][^#]*?:(?:[ \t]|$))"
)
# A `services` key wherever a key can start, in any spelling: the reader takes only a
# plain `services:` line (_YAML_SERVICES_RE), so a quoted, spaced, anchored or flow
# one is unreadable. A scan: .search.
_YAML_SERVICES_KEY_RE = re.compile(
    rf"(?:^|[{{\[,])[ \t]*(?:-[ \t]+)*{_YAML_KEY_PROPERTIES}([\"']?)services\1[ \t]*:"
)
# Compose build keys that replace the frontend or a stage's image: unreadable in every
# shape, map or `- KEY=value` list. A scan: .search.
_YAML_BUILD_OVERRIDE_RE = re.compile(r"BUILDKIT_SYNTAX|additional_contexts")
# The one shape read: a block-style `key: value` (or `- key: value`) with the value on
# the key's own line. A validator: .fullmatch.
_YAML_PIN_LINE_RE = re.compile(r"[ \t]*(?:-[ \t]+)?(uses|image|container|dockerfile):[ \t]+(\S.*)")
# A bare `container:`, perhaps anchored or commented: the mapping form, read through
# its `image:` child. A validator: .fullmatch.
_YAML_CONTAINER_MAPPING_RE = re.compile(r"[ \t]*(?:-[ \t]+)?(container):(?:[ \t]+&[^ \t#]+)?(?:[ \t]+(?:#.*)?)?")
# The line a mapping form must continue with: a plain key, deeper than its parent (a
# merge key `<<:` included). A validator: .fullmatch.
_YAML_MAPPING_KEY_RE = re.compile(r"[ \t]*(?:[\w-]+|<<):(?:[ \t].*)?")
# A block scalar opener, `key: |` or `- >-`, with the column its content must exceed:
# the key's, or the indicator's in a sequence. An explicit indentation indicator
# (`|2`) fixes the content's indent at that column plus the indicator. A quoted,
# tagged or anchored key does not open one here, so its content is read as
# structure: stricter, never looser. A validator: .fullmatch.
_YAML_BLOCK_SCALAR_RE = re.compile(
    r"(?P<lead>[ \t]*(?:-[ \t]+)*)(?:[^ \t#'\"{\[?*&!:][^#'\"]*?:[ \t]+)?"
    r"[|>](?P<flags>[0-9+-]*)(?:[ \t]+#.*)?[ \t]*"
)
_YAML_INDENT_INDICATOR_RE = re.compile(r"[1-9]")
# `services:`, compose's or a workflow job's, and one of its children, `<id>: ...`.
# Validators: .fullmatch.
_YAML_SERVICES_RE = re.compile(r"([ \t]*)services:(?:[ \t]+(.*))?")
_YAML_SERVICE_RE = re.compile(r"[ \t]*[\w.-]+:(?:[ \t]+(.*))?")
# Compose sections read entry by entry: `include:` (paths, or `path:` items),
# `extends:` (`file:` and `service:`) and a build's `args:`, where a list-form name
# holding an interpolation could spell BUILDKIT_SYNTAX. Validators: .fullmatch.
_YAML_SECTION_RE = re.compile(r"[ \t]*(include|extends|args):(?:[ \t]+(.*))?")
_YAML_INCLUDE_ITEM_RE = re.compile(r"[ \t]*-[ \t]+(?:path:[ \t]+)?(\S.*)")
# `- path:` alone: its paths follow as list items, each read as an entry.
_YAML_INCLUDE_PATHS_RE = re.compile(r"[ \t]*-[ \t]+path:(?:[ \t]+#.*)?[ \t]*")
_YAML_EXTENDS_KEY_RE = re.compile(r"[ \t]*(file|service):[ \t]+(\S.*)")
_YAML_LIST_ITEM_RE = re.compile(r"[ \t]*-[ \t]+(\S.*)")
_YAML_ANCHOR_RE = re.compile(r"&[^ \t]+")
_YAML_EMPTY_FLOW = ("{}", "[]")
# A service value that is an alias or a flow collection: not a scalar image.
_YAML_UNREAD_VALUE = ("*", "{", "[")
_INTERPOLATION = "${"
_USES = "uses"
_IMAGE = "image"
_DOCKERFILE = "dockerfile"
_INCLUDE = "include"
_EXTENDS = "extends"
_ARGS = "args"
_EXTENDS_FILE = "extends-file"
_MAPPING = "mapping"
_SCALAR = "scalar"
# owner/repo plus an optional path inside it (a composite action or a reusable
# workflow), then the full lowercase commit SHA. A validator: .fullmatch.
_ACTION_PIN_RE = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*@[0-9a-f]{40}")
_ACTION_VERSION_RE = re.compile(r"v\d+\.\d+\.\d+")
_LOCAL_ACTION_PREFIX = "./"
_ACTION_FILES = ("action.yml", "action.yaml")
_YAML_SUFFIXES = (".yml", ".yaml")
_DOCKER_PREFIX = "docker://"
_URL_MARK = "://"


def _clean_value(value: str) -> str:
    """Strip a trailing ` #` comment and surrounding quotes.

    " #" opens a comment well enough here, and errs the safe way: a comment can
    neither supply nor hide a pin.
    """
    head = value.split(" #", 1)[0].strip()
    return head[1:-1] if len(head) >= 2 and head[0] == head[-1] and head[0] in "\"'" else head


def _inline_value(raw: str | None) -> str:
    """A key's inline value, cleaned; empty when there is none or only a comment."""
    return "" if raw is None or raw.lstrip().startswith("#") else _clean_value(raw)


_ScanState = tuple[str, int, bool, bool]


def _yaml_scan(line: str, state: _ScanState | None) -> tuple[_ScanState | None, bool, bool]:
    """Follow quoted scalars and flow collections across one line.

    *state* is what an earlier line left open, (quote, flow depth, at a node start,
    just after a closing quote), or None at the start of a block line. Returns what
    this line leaves open (None for nothing), whether a double-quoted scalar on it
    holds a backslash escape, and whether a flow collection on it holds anything but
    scalars in sequences: a `{`, a `:` value indicator (JSON-style `"a":b` too), or a
    `?`, anchor, tag or alias where a node starts. A quote opens a scalar only where a
    node starts (the line's start, after `- `, `? `, `: `, a flow opener or a comma),
    and a `{` or `[` a collection only there or inside another one; elsewhere they are
    plain text. YAML parsers hold the lines inside a quoted scalar or a flow
    collection to no indentation, so what this reader would take for structure there
    is not.
    """
    quote, depth, node, closed = state if state is not None else ("", 0, True, False)
    escaped = mapped = False
    index = 0
    while index < len(line):
        char, after = line[index], line[index + 1 : index + 2]
        was_closed, closed = closed, False
        if quote == '"':
            if char == "\\":
                escaped, index = True, index + 2
                continue
            if char == '"':
                quote, node, closed = "", False, True
        elif quote == "'":
            if char == "'" and after == "'":
                index += 2
                continue
            if char == "'":
                quote, node, closed = "", False, True
        elif char in " \t":
            closed = was_closed
        elif char == "#" and (index == 0 or line[index - 1] in " \t"):
            break
        elif node and char in "\"'":
            quote = char
        elif node and char in "&!*":
            mapped |= depth > 0
            while index < len(line) and line[index] not in " \t":
                index += 1
            continue
        elif char in "{[" and (node or depth):
            mapped |= char == "{"
            depth, node = depth + 1, True
        elif depth and char in "}]":
            depth, node = depth - 1, False
        elif depth and char == ",":
            node = True
        elif char == ":" and (after in ("", " ", "\t") or (depth and (after in ",]}" or was_closed))):
            mapped |= depth > 0
            node = True
        elif node and char in "-?" and after in ("", " ", "\t"):
            mapped |= depth > 0 and char == "?"
        else:
            node = False
        index += 1
    return ((quote, depth, node, closed) if quote or depth else None), escaped, mapped


def _pin_line(line: str) -> tuple[str, str, str | None, int] | None:
    """The pin-key read of one live line: (kind, value, comment, key column).

    Kind "uses", "image", "container" or "dockerfile" with the _clean_value'd value and
    the stripped trailing comment (None when there is none); "mapping" for a bare
    `container:`; "unclassified", with the stripped line, for a pin key in any other
    shape. None when the line holds no pin key.
    """
    if _YAML_PIN_KEY_RE.search(line) is None:
        return None
    if (mapping := _YAML_CONTAINER_MAPPING_RE.fullmatch(line)) is not None:
        return _MAPPING, "", None, mapping.start(1)
    if (read := _YAML_PIN_LINE_RE.fullmatch(line)) is None:
        return _UNCLASSIFIED, line.strip(), None, 0
    rest = read.group(2)
    _, marker, comment = rest.partition(" #")
    return read.group(1), _clean_value(rest), comment.strip() if marker else None, read.start(1)


def _section_line(kind: str, line: str) -> tuple[str, str] | None:
    """One line inside a compose `include:`, `extends:` or `args:` section: (kind,
    value) to yield, or None when it names nothing to check."""
    if kind == _INCLUDE:
        if _YAML_INCLUDE_PATHS_RE.fullmatch(line):
            return None
        item = _YAML_INCLUDE_ITEM_RE.fullmatch(line)
        return (_INCLUDE, _clean_value(item.group(1))) if item else (_UNCLASSIFIED, line.strip())
    if kind == _EXTENDS:
        key = _YAML_EXTENDS_KEY_RE.fullmatch(line)
        if key is None:
            return _UNCLASSIFIED, line.strip()
        return (_EXTENDS_FILE, _clean_value(key.group(2))) if key.group(1) == "file" else None
    item = _YAML_LIST_ITEM_RE.fullmatch(line)
    named = item is not None and _INTERPOLATION in _clean_value(item.group(1)).split("=", 1)[0]
    return (_UNCLASSIFIED, line.strip()) if named else None


def yaml_references(text: str, compose: bool = False) -> Iterator[tuple[int, str, str, str | None]]:
    """Every live `uses:`, `image:`, `container:` and `dockerfile:` value in a YAML text,
    and, in a compose file (*compose*), every path its `include:` and `extends:` name.

    Yields (lineno, kind, value, comment): kind "uses", "image", "container" (its
    scalar form), "dockerfile", "include" or "extends-file" with the _clean_value'd
    value and the stripped trailing comment, or None; or kind "unclassified" with the
    stripped line for a line this reader cannot read:

    - a pin key (_YAML_PIN_KEY_RE) in any shape but `key: value` on one line, and any
      `dockerfile_inline:`, BUILDKIT_SYNTAX or additional_contexts line;
    - a key position holding "?", ":", an alias or a tag (_YAML_ODD_KEY_RE), and a
      `services` key in any spelling but a plain `services:` line;
    - a line holding a YAML 1.1 line break;
    - a line that opens a quoted scalar and does not close it, or a flow collection
      continued on later lines that holds anything but scalars in sequences
      (_yaml_scan), reported at its opening line; the lines it continues on are
      skipped, since a parser holds them to no indentation. Also a double-quoted
      scalar holding a backslash escape;
    - after a pin-key value, a deeper next live line (a plain scalar continued);
    - after a bare `container:` or service `<id>:`, a next live line that is not a
      deeper plain `key:` line (a value on a later line, or behind a comment or alias);
    - under `services:`, a child that is not `<id>:` or `<id>: <value>`, or whose value
      is an alias or a flow collection. A child's scalar value is yielded as "image";
    - in a compose file, an `include:` entry that is not a path or a `path:` item, an
      inline `include:` value, an `extends:` key other than `file:` and `service:`, a
      flow `extends:`, and a build argument whose list-form name or inline `args:`
      value holds `${`.

    A line reader, not a YAML parse: a line whose first non-blank character is "#" is
    dead, and lines split on YAML's own breaks after a leading BOM is removed. A block
    scalar's content (`run: |`) is not structure: only its pin-key lines are read in it,
    a false positive, but a closed one.
    """
    block_column: int | None = None  # the column a block scalar's content must exceed
    block_indent: int | None = None  # its content's indent, once known
    expect: tuple[str, int] | None = None  # what the next live line must be, and its parent column
    services: int | None = None  # the column of an open `services:`
    child: int | None = None  # the indent of its children
    section: tuple[str, int] | None = None  # an open compose include/extends/args, and its column
    scalar: _ScanState | None = None  # a quoted scalar or flow collection still open
    span: tuple[int, str] | None = None  # the line that opened a multi-line flow sequence, if still clean
    span_unread = False  # whether that sequence holds anything but scalars
    for lineno, line in enumerate(_YAML_LINE_BREAK_RE.split(text.removeprefix("\ufeff")), start=1):
        if _YAML_FOREIGN_BREAK_RE.search(line) is not None:
            yield lineno, _UNCLASSIFIED, line.strip(), None
            continue
        if scalar is not None:
            scalar, escaped, mapped = _yaml_scan(line, scalar)
            span_unread |= escaped or mapped or any(
                pattern.search(line) is not None
                for pattern in (_YAML_PIN_KEY_RE, _YAML_SERVICES_KEY_RE, _YAML_BUILD_OVERRIDE_RE)
            )
            if scalar is None and span is not None and span_unread:
                yield span[0], _UNCLASSIFIED, span[1], None
            span = None if scalar is None else span
            continue
        indent = len(line) - len(line.lstrip(" "))
        stripped = line.strip(" \t")
        if block_column is not None and stripped:
            if block_indent is None and indent > block_column:
                block_indent = indent
            if block_indent is not None and indent >= block_indent:
                if not stripped.startswith("#"):
                    if _YAML_BUILD_OVERRIDE_RE.search(line) is not None:
                        yield lineno, _UNCLASSIFIED, line.strip(), None
                    elif (read := _pin_line(line)) is not None and read[0] != _MAPPING:
                        yield lineno, *read[:3]
                continue
            block_column = block_indent = None
        if not stripped or stripped.startswith("#"):
            continue
        unread = _YAML_ODD_KEY_RE.search(line) is not None or _YAML_BUILD_OVERRIDE_RE.search(line) is not None
        unread |= _YAML_SERVICES_KEY_RE.search(line) is not None and _YAML_SERVICES_RE.fullmatch(line) is None
        if expect is not None:
            shape, column = expect
            deeper = indent > column
            unread |= deeper if shape == _SCALAR else not (deeper and _YAML_MAPPING_KEY_RE.fullmatch(line))
            expect = None
        if services is not None and indent <= services:
            services = child = None
        if section is not None and not (indent > section[1] or (indent == section[1] and stripped.startswith("- "))):
            section = None
        scalar, escaped, mapped = _yaml_scan(line, None)
        if unread or escaped or (scalar is not None and (scalar[0] or mapped)):
            yield lineno, _UNCLASSIFIED, line.strip(), None
            continue
        if scalar is not None:  # a flow sequence continued on the next lines: judged when it closes
            span, span_unread = (lineno, line.strip()), False
        if (block := _YAML_BLOCK_SCALAR_RE.fullmatch(line)) is not None:
            block_column = len(block.group("lead"))
            explicit = _YAML_INDENT_INDICATOR_RE.search(block.group("flags"))
            block_indent = block_column + int(explicit.group()) if explicit else None
        if section is not None:
            if (entry := _section_line(section[0], line)) is not None:
                yield lineno, *entry, None
            continue
        if services is not None:
            child = indent if child is None else child
        if services is not None and indent == child:
            if (service := _YAML_SERVICE_RE.fullmatch(line)) is None:
                yield lineno, _UNCLASSIFIED, line.strip(), None
                continue
            value = _inline_value(service.group(1))
            if not value or _YAML_ANCHOR_RE.fullmatch(value):
                expect = (_MAPPING, indent)
            elif value.startswith(_YAML_UNREAD_VALUE):
                yield lineno, _UNCLASSIFIED, line.strip(), None
            else:
                yield lineno, _IMAGE, value, None
                expect = None if block else (_SCALAR, indent)
            continue
        if (opened := _YAML_SERVICES_RE.fullmatch(line)) is not None:
            value = _inline_value(opened.group(2))
            if not value or _YAML_ANCHOR_RE.fullmatch(value):
                services, child = len(opened.group(1)), None
            elif value not in _YAML_EMPTY_FLOW:
                yield lineno, _UNCLASSIFIED, line.strip(), None
            continue
        if compose and (opened := _YAML_SECTION_RE.fullmatch(line)) is not None:
            kind, value = opened.group(1), _inline_value(opened.group(2))
            if not value or _YAML_ANCHOR_RE.fullmatch(value):
                section = (kind, indent)
            elif kind == _INCLUDE or value.startswith(_YAML_UNREAD_VALUE) or _INTERPOLATION in value:
                yield lineno, _UNCLASSIFIED, line.strip(), None
            continue
        if (read := _pin_line(line)) is None:
            continue
        kind, value, comment, column = read
        if kind == _MAPPING:
            expect = (_MAPPING, column)
            continue
        yield lineno, kind, value, comment
        if kind != _UNCLASSIFIED and block is None:
            expect = (_SCALAR, column)
    if span is not None:
        yield span[0], _UNCLASSIFIED, span[1], None


def _action_message(value: str, comment: str | None, first_party: tuple[str, ...]) -> str | None:
    """The violation message for one `uses:` value, or None if it passes. A `./` value
    is checked against the listing by _local_action_message."""
    if value.startswith(_LOCAL_ACTION_PREFIX):
        return None
    if value.startswith(_DOCKER_PREFIX):
        return _image_message(value.removeprefix(_DOCKER_PREFIX), first_party)
    if _URL_MARK in value:
        return (
            f"action reference {value!r} is an absolute URL: it is fetched from that host "
            "instead of the runner's default action host; spell it "
            "'owner/repo@<40 lowercase hex> # vX.Y.Z' from the default host"
        )
    if _ACTION_PIN_RE.fullmatch(value) is None:
        return (
            f"action reference {value!r} is not pinned to a full commit SHA: spell it "
            "'owner/repo[/path]@<40 lowercase hex> # vX.Y.Z'; a tag or branch can move under the "
            "same name, and a short or uppercase SHA is not the form a pin is checked in"
        )
    if comment is not None and _ACTION_VERSION_RE.fullmatch(comment):
        return None
    found = "no comment" if comment is None else f"'# {comment}'"
    return (
        f"action pin {value!r} carries {found} where an exact '# vX.Y.Z' is required: the "
        "comment names the release the SHA was resolved from, so an update can be checked "
        "against it, and a floating '# vN' names no single commit"
    )


def _local_action_message(value: str, listed: set[str]) -> str | None:
    """A `./<dir>` action must have its action.yml or action.yaml in *listed*, and a
    `./<file>.yml` reusable workflow must itself be listed: what it runs is read there."""
    target = posixpath.normpath(value.removeprefix(_LOCAL_ACTION_PREFIX))
    prefix = "" if target == "." else f"{target}/"
    wanted = (target,) if target.endswith(_YAML_SUFFIXES) else tuple(prefix + name for name in _ACTION_FILES)
    if listed.intersection(wanted):
        return None
    return (
        f"local action {value!r} names no {' or '.join(wanted)} that git lists in the repository, "
        "so the references it runs cannot be read; commit the action with the project"
    )


def _resolve(base: str, value: str) -> str | None:
    """*value* as a repository path, relative to the directory of the file *base*; None
    when it is absolute, a URL, or leads out of the repository."""
    if value.startswith("/") or _URL_MARK in value:
        return None
    resolved = posixpath.normpath(posixpath.join(posixpath.dirname(base), value))
    return None if resolved == ".." or resolved.startswith("../") else resolved


def _is_dockerfile_path(path: str | None) -> bool:
    """Whether a resolved path is one the Dockerfile family reads (never a YAML file)."""
    return path is not None and family(path) == _DOCKERFILE_FAMILY and not path.endswith(_YAML_SUFFIXES)


def _named_file_message(kind: str, path: str, value: str, listed: set[str]) -> str | None:
    """A file a YAML file names: a compose `dockerfile:` must be named as a Dockerfile
    inside the repository (it resolves against the build context, which is not
    followed); an action's Dockerfile `image:` must be a Dockerfile git lists, resolved
    against the action's directory; an `include:` or `extends:` file must be a compose
    file git lists, resolved against the compose file's directory."""
    resolved = _resolve(path, value)
    if kind == _DOCKERFILE:
        if _is_dockerfile_path(resolved):
            return None
        wanted = (
            "a path inside the repository named as a Dockerfile (Dockerfile, Containerfile, Dockerfile.<suffix>, ...)"
        )
    elif kind == _IMAGE:
        if _is_dockerfile_path(resolved) and resolved in listed:
            return None
        wanted = "a Dockerfile that git lists, relative to the action's directory"
    else:
        if resolved in listed and family(resolved) == _COMPOSE_FAMILY:
            return None
        wanted = "a compose file that git lists, relative to this file's directory"
    label = {_EXTENDS_FILE: "extends file", _INCLUDE: "include file"}.get(kind, kind)
    return f"{label} {value!r} is not {wanted}, so the pin check cannot read the images it names"


def _yaml_messages(
    text: str, first_party: tuple[str, ...], path: str, kind_of_file: str | None, listed: set[str]
) -> Iterator[tuple[int, str]]:
    action = kind_of_file == _ACTION_FAMILY
    for lineno, kind, value, comment in yaml_references(text, compose=kind_of_file == _COMPOSE_FAMILY):
        if kind == _UNCLASSIFIED:
            message: str | None = (
                f"live line {value!r} is in a shape this check cannot read (a flow mapping, or a "
                "quoted or flow value continued on another line; a quoted, escaped, spaced, tagged, "
                "anchored, aliased or explicit '?' key, or a backslash escape in a double-quoted "
                "value; a value continued on a deeper line, or a container or service mapping that "
                "does not start on the next line; a U+0085, U+2028 or U+2029 line break; "
                "dockerfile_inline, BUILDKIT_SYNTAX, additional_contexts or a build argument named "
                "by a variable; an include: or extends: entry other than a plain path), so a "
                "reference there would escape the pin check; write '<key>: <value>' on the key's "
                "own line, and keep a Dockerfile and its frontend in a Dockerfile"
            )
        elif kind == _USES:
            local = value.startswith(_LOCAL_ACTION_PREFIX)
            message = _local_action_message(value, listed) if local else _action_message(value, comment, first_party)
        elif kind in (_DOCKERFILE, _INCLUDE, _EXTENDS_FILE):
            message = _named_file_message(kind, path, value, listed)
        elif kind == _IMAGE and action and _URL_MARK not in value and is_dockerfile(value):
            message = _named_file_message(_IMAGE, path, value, listed)  # a Docker container action's Dockerfile
        else:
            token = value.removeprefix(_DOCKER_PREFIX) if kind == _IMAGE else value
            message = _image_message(token, first_party)
        if message is not None:
            yield lineno, message


def check_files(files: dict[str, str], first_party: tuple[str, ...]) -> list[Violation]:
    """Every unpinned or unreadable reference in *files* ({path: text}).

    Each file is read by its family (family): a Dockerfile with dockerfile_references,
    everything else as YAML, where every key is read in every file. A file another one
    names (a `./` action, an action's Dockerfile, a compose `include:` or `extends:`) is
    looked up among the paths of *files*.
    """
    listed = set(files)
    violations: list[Violation] = []
    for path in sorted(files):
        kind = family(path)
        if kind == _DOCKERFILE_FAMILY:
            sites = _dockerfile_messages(files[path], first_party)
        else:
            sites = _yaml_messages(files[path], first_party, path, kind, listed)
        violations += [Violation(path, lineno, message) for lineno, message in sites]
    return violations


# --- the project: devkit.toml, git, the families ----------------------------

PINS_KEYS = frozenset({"first-party"})
_WORKFLOW_FAMILY = "workflow"
_ACTION_FAMILY = "action"
_COMPOSE_FAMILY = "compose file"
_DOCKERFILE_FAMILY = "Dockerfile"
FAMILIES = (_WORKFLOW_FAMILY, _ACTION_FAMILY, _COMPOSE_FAMILY, _DOCKERFILE_FAMILY)
_WORKFLOW_DIRS = (".gitea/workflows/", ".github/workflows/")
_COMPOSE_PREFIXES = ("compose", "docker-compose")


def load_first_party(toml_path: Path) -> tuple[str, ...]:
    """The namespaces `[pins] first-party` lists; none when the file or table is absent.

    Raises ValueError, naming devkit.toml, on invalid TOML, an unknown key under
    [pins], a value that is not a list, and an entry that is not a lowercase image
    name without tag or digest.
    """
    if not toml_path.is_file():
        return ()
    try:
        with toml_path.open("rb") as handle:
            pins = tomllib.load(handle).get("pins", {})
    except (OSError, ValueError) as exc:  # TOMLDecodeError subclasses ValueError
        raise ValueError(f"cannot read {toml_path.name}: {exc}") from exc
    if not isinstance(pins, dict):
        raise ValueError(f"{toml_path.name}: pins must be the table [pins]")
    if stray := sorted(set(pins) - PINS_KEYS):
        raise ValueError(f"{toml_path.name}: unknown key(s) under [pins]: {', '.join(stray)}; only first-party is read")
    entries = pins.get("first-party", [])
    if not isinstance(entries, list):
        raise ValueError(f'{toml_path.name}: [pins] first-party must be a list, e.g. ["registry.example/team"]')
    for entry in entries:
        if not (isinstance(entry, str) and entry == entry.lower() and _IMAGE_NAME_RE.fullmatch(entry)):
            raise ValueError(
                f"{toml_path.name}: [pins] first-party entry {entry!r} is not a lowercase image "
                "namespace without tag or digest, e.g. \"registry.example/team\""
            )
    return tuple(entries)


def family(path: str) -> str | None:
    """Which of FAMILIES a repository-relative path belongs to, if any, in that order:
    a .y{a,}ml under .gitea/workflows/ or .github/workflows/; any action.y{a,}ml; a
    compose*.y{a,}ml or docker-compose*.y{a,}ml; a Dockerfile (is_dockerfile)."""
    name = path.rpartition("/")[2]
    is_yaml = name.endswith(_YAML_SUFFIXES)
    if is_yaml and path.startswith(_WORKFLOW_DIRS):
        return _WORKFLOW_FAMILY
    if name in _ACTION_FILES:
        return _ACTION_FAMILY
    if is_yaml and name.startswith(_COMPOSE_PREFIXES):
        return _COMPOSE_FAMILY
    return _DOCKERFILE_FAMILY if is_dockerfile(path) else None


def listed_files(root: Path) -> list[str]:
    """The files git lists in *root*: tracked, plus untracked ones not ignored; tracked
    files deleted from disk are skipped. Raises Failure when git cannot list them."""
    try:
        listing = subprocess.run(
            ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
            cwd=root,
            capture_output=True,
            check=False,
        )
    except OSError as exc:
        raise Failure(f"cannot run git to list the repository's files: {exc.strerror}") from exc
    if listing.returncode != 0:
        reason = listing.stderr.decode(errors="replace").strip().splitlines()
        raise Failure(f"git cannot list the files in {root}: {reason[0] if reason else 'git failed'}")
    paths = {os.fsdecode(raw) for raw in listing.stdout.split(b"\0") if raw}
    return sorted(path for path in paths if os.path.lexists(root / path))


def read_family_files(root: Path, paths: list[str]) -> tuple[dict[str, str], list[Violation]]:
    """The texts of *paths*, and a violation for each one that is a symlink or unreadable."""
    files: dict[str, str] = {}
    violations: list[Violation] = []
    for path in paths:
        full = root / path
        if full.is_symlink():
            violations.append(
                Violation(path, 0, "is a symlink: the pin check does not follow links; commit the file itself here")
            )
            continue
        try:
            # Bytes, not read_text: universal newlines would move the line breaks the readers model.
            files[path] = full.read_bytes().decode("utf-8")
        except (OSError, UnicodeDecodeError) as exc:
            reason = exc.strerror if isinstance(exc, OSError) else "not UTF-8"
            violations.append(Violation(path, 0, f"cannot be read ({reason}), so its references cannot be checked"))
    return files, violations


def census(counts: dict[str, int]) -> str:
    named = ", ".join(f"{counts[name]} {name}{'' if counts[name] == 1 else 's'}" for name in FAMILIES)
    return f"reference pins: {named} checked"


def main() -> None:
    root = Path(os.environ.get("PROJECT_ROOT") or ".").resolve()
    try:
        first_party = load_first_party(root / "devkit.toml")
        listed = [(path, family(path)) for path in listed_files(root)]
    except (ValueError, Failure) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(1)
    paths = [path for path, kind in listed if kind is not None]
    files, violations = read_family_files(root, paths)
    violations += check_files(files, first_party)
    print(census({name: sum(kind == name for _, kind in listed) for name in FAMILIES}), flush=True)
    for violation in sorted(violations, key=lambda v: (v.file, v.line)):
        print(violation, file=sys.stderr)
    if violations:
        sys.exit(1)


if __name__ == "__main__":
    main()
