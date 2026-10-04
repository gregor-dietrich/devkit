#!/usr/bin/env python3
"""Table tests for scripts/check_pins.py's pure part, check_files: per row, a set of
{path: text} files, the first-party namespaces, the substrings the rendered
violations (file:line: message, one per line) must contain, and the exact violation
count. Run by tests/check_pins_test.sh with scripts/ on PYTHONPATH; prints PASS/FAIL
per row and exits 1 on any failure."""

import sys

from check_pins import check_files

NS = ("registry.example/first-party",)
SHA = "3d3c42e5aac5ba805825da76410c181273ba90b1"
DIGEST = "@sha256:" + "0123456789abcdef" * 4
CHECKOUT = f"actions/checkout@{SHA}"
POSTGRES = f"postgres:18.6-alpine3.24{DIGEST}"
UNPINNED = "is not pinned as"
NOT_SHA = "is not pinned to a full commit SHA"
NOT_EXACT = "where an exact '# vX.Y.Z' is required"
UNREAD = "is in a shape this check cannot read"
URL = "is an absolute URL"
UNPARSED = "does not parse as"


def steps(*lines: str) -> dict[str, str]:
    """A one-job workflow whose steps are *lines*, from line 4 on."""
    return {"ci.yml": "jobs:\n  a:\n    steps:\n" + "".join(f"      {line}\n" for line in lines)}


def compose(*images: str) -> dict[str, str]:
    """A compose file whose services' image: lines are 3, 5, 7, ..."""
    body = "".join(f"  s{i}:\n    image: {image}\n" for i, image in enumerate(images))
    return {"docker-compose.yml": f"services:\n{body}"}


ROWS: tuple[tuple[str, dict[str, str], tuple[str, ...], tuple[str, ...], int], ...] = (
    (
        "the clean shapes, and every exemption",
        {
            "Dockerfile": (
                f"FROM python:3.14.7-alpine3.24{DIGEST} AS builder\n"
                f"COPY --from=ghcr.io/astral-sh/uv:0.12.10{DIGEST} /uv /usr/bin/\n"
                "FROM scratch AS assets\n"
                f"FROM python:3.14.7-slim{DIGEST} AS runtime\n"
                "COPY --from=builder /app /app\n"
                "COPY --from=0 /x /x\n"
                "# FROM python:3.13.0\n"
            ),
            "docker-compose.yml": (
                "services:\n"
                "  app:\n"
                f"    image: {NS[0]}/app:0.1.0\n"
                "  db:\n"
                f'    image: "{POSTGRES}"\n'
                "# pgadmin:\n"
                "#   image: dpage/pgadmin4:9.17\n"
            ),
            "ci.yml": (
                "# The `uses:` steps are left bare; image: in prose\n"
                "jobs:\n"
                "  a:\n"
                "    container:\n"
                f"      image: node:22{DIGEST}\n"
                "    steps:\n"
                f"      - uses: {CHECKOUT} # v7.0.1\n"
                f"      - uses: 'owner/repo/sub/path@{SHA}'  #  v1.2.3\n"
                "      - uses: ./.gitea/actions/local\n"
                f"      - uses: docker://alpine:3.24{DIGEST}\n"
                '      - run: echo "image: x" uses: y\n'
                "        # - uses: actions/checkout@v7\n"
                "  b:\n"
                f"    uses: o/r/.gitea/workflows/w.yml@{SHA} # v1.0.0\n"
            ),
            ".gitea/actions/local/action.yml": f"runs:\n  using: docker\n  image: docker://alpine:3.24{DIGEST}\n",
        },
        NS,
        (),
        0,
    ),
    (
        "a trailing comment is not part of the value",
        {"compose.yaml": f"services:\n  mailpit:\n    image: axllent/mailpit:v1.31.1{DIGEST} # never :latest\n"},
        NS,
        (),
        0,
    ),
    (
        "a bare tag, in a FROM and in a COPY --from=",
        {
            "Dockerfile": (
                "FROM python:3.14.7-alpine3.24 AS builder\n"
                "COPY --from=ghcr.io/astral-sh/uv:0.12.10 /uv /usr/bin/\n"
            )
        },
        NS,
        (
            f"Dockerfile:1: image reference 'python:3.14.7-alpine3.24' {UNPINNED} 'python:<tag>@sha256:<64 hex>': "
            "it carries no digest",
            f"Dockerfile:2: image reference 'ghcr.io/astral-sh/uv:0.12.10' {UNPINNED}",
        ),
        2,
    ),
    (
        "a bare tag, a tagless digest and neither, in compose",
        compose("postgres:18.6-alpine3.24", f"postgres{DIGEST}", "postgres"),
        NS,
        (
            f"docker-compose.yml:3: image reference 'postgres:18.6-alpine3.24' {UNPINNED} "
            "'postgres:<tag>@sha256:<64 hex>': it carries no digest;",
            "docker-compose.yml:5: image reference 'postgres@sha256:",
            "it carries no tag;",
            f"docker-compose.yml:7: image reference 'postgres' {UNPINNED} 'postgres:<tag>@sha256:<64 hex>': "
            "it carries no tag or digest;",
        ),
        3,
    ),
    (
        # The first-party test runs on the repository part before the full parse, so a
        # first-party image with a variable tag is exempt; a variable repository is not.
        "an unparseable image fails, unless its repository part is first-party",
        compose("${IMAGE}", f"{NS[0]}/app:${{TAG}}", ">-", f"${{NS}}/app:1{DIGEST}"),
        NS,
        (
            f"docker-compose.yml:3: image reference '${{IMAGE}}' {UNPARSED}",
            f"docker-compose.yml:7: image reference '>-' {UNPARSED}",
            f"docker-compose.yml:9: image reference '${{NS}}/app:1{DIGEST}' {UNPARSED}",
        ),
        3,
    ),
    (
        "a tag, a short SHA and an uppercase SHA are not the full SHA",
        steps(
            "- uses: actions/checkout@v7 # v7.0.1",
            "- uses: actions/checkout@3d3c42e # v7.0.1",
            f"- uses: actions/checkout@{SHA.upper()} # v7.0.1",
        ),
        NS,
        (
            f"ci.yml:4: action reference 'actions/checkout@v7' {NOT_SHA}",
            f"ci.yml:5: action reference 'actions/checkout@3d3c42e' {NOT_SHA}",
            "ci.yml:6: action reference 'actions/checkout@3D3C42E5",
        ),
        3,
    ),
    (
        "a floating '# v7', no comment, and an exact version with more after it",
        steps(f"- uses: {CHECKOUT} # v7", f"- uses: {CHECKOUT}", f"- uses: {CHECKOUT} # v7.0.1 (pinned)"),
        NS,
        (
            f"ci.yml:4: action pin '{CHECKOUT}' carries '# v7' {NOT_EXACT}",
            f"ci.yml:5: action pin '{CHECKOUT}' carries no comment {NOT_EXACT}",
            f"ci.yml:6: action pin '{CHECKOUT}' carries '# v7.0.1 (pinned)' {NOT_EXACT}",
        ),
        3,
    ),
    (
        "a docker:// action is held to the image rule",
        steps("- uses: docker://alpine:3.24"),
        NS,
        (f"ci.yml:4: image reference 'alpine:3.24' {UNPINNED}",),
        1,
    ),
    (
        "unreadable uses: lines: a flow mapping, a quoted key, a spaced key, a value on a later line",
        steps(f"- {{uses: {CHECKOUT}}}", f'- "uses": {CHECKOUT} # v7.0.1', f"- uses : {CHECKOUT} # v7.0.1", "- uses:"),
        NS,
        (
            f"ci.yml:4: live line '- {{uses: {CHECKOUT}}}' {UNREAD}",
            "ci.yml:5: live line '- \"uses\": ",
            "ci.yml:6: live line '- uses : ",
            f"ci.yml:7: live line '- uses:' {UNREAD}",
        ),
        4,
    ),
    (
        "unreadable image: lines",
        {
            "docker-compose.yml": (
                "services:\n"
                f"  a: {{image: {POSTGRES}}}\n"
                "  b:\n"
                "    image:\n"
                f"      {POSTGRES}\n"
                f"  c: [x, image: {POSTGRES}]\n"
            )
        },
        NS,
        (
            f"docker-compose.yml:2: live line 'a: {{image: {POSTGRES}}}' {UNREAD}",
            f"docker-compose.yml:4: live line 'image:' {UNREAD}",
            "docker-compose.yml:6: live line 'c: [x, image: ",
        ),
        3,
    ),
    (
        "YAML's own line breaks: a BOM, CRLF and a lone CR",
        {"ci.yml": "\ufeffjobs:\r\n  a:\r    steps:\n      - uses: actions/checkout@v7\r\n"},
        NS,
        (f"ci.yml:4: action reference 'actions/checkout@v7' {NOT_SHA}",),
        1,
    ),
    (
        # An unparseable FROM and a build source outside COPY --from= fail on their own
        # lines, and the reader goes on to the next reference.
        "an unreadable Dockerfile line or token fails, and the next reference is still read",
        {
            "Dockerfile": (
                "FROM ${BASE} AS builder\n"
                "RUN --mount=type=bind,from=python:3.14.7,target=/p true\n"
                "FROM python:3.14.7-alpine3.24\n"
            )
        },
        NS,
        (
            f"Dockerfile:1: image reference '${{BASE}}' {UNPARSED}",
            f"Dockerfile:2: live line 'RUN --mount=type=bind,from=python:3.14.7,target=/p true' {UNREAD}",
            f"Dockerfile:3: image reference 'python:3.14.7-alpine3.24' {UNPINNED}",
        ),
        3,
    ),
    (
        "a pinned scalar container:, the mapping form's bare line, keys in comments after a flow opener",
        {
            "ci.yml": (
                "jobs:\n"
                "  a:\n"
                f"    container: node:22{DIGEST}\n"
                "  b:\n"
                "    container:  # the mapping form\n"
                f"      image: node:22{DIGEST}\n"
                "    steps:\n"
                "      # {uses: actions/checkout@v7}\n"
                "      # a, image: postgres:18\n"
                f"      - uses: {CHECKOUT} # v7.0.1\n"
            )
        },
        NS,
        (),
        0,
    ),
    (
        "a scalar container: is an image; the mapping form is blamed at its image: line",
        {
            "ci.yml": (
                "jobs:\n"
                "  a:\n"
                "    container: alpine:3\n"
                "  b:\n"
                "    container:\n"
                "      image: alpine:3\n"
                "  c:\n"
                '    container: "${{ matrix.image }}"\n'
            )
        },
        NS,
        (
            f"ci.yml:3: image reference 'alpine:3' {UNPINNED}",
            f"ci.yml:6: image reference 'alpine:3' {UNPINNED}",
            f"ci.yml:8: image reference '${{{{ matrix.image }}}}' {UNPARSED}",
        ),
        3,
    ),
    (
        "a YAML 1.1 line break (NEL, LS, PS) fails its line, comment or not",
        {
            "docker-compose.yml": (
                "services:\n"
                "  db:\n"
                "    restart: x\u2028    image: attacker/pg:16\n"
                "    # note\u2029image: attacker/pg:16\n"
                "    labels: [a\x85]\n"
            )
        },
        NS,
        (
            f"docker-compose.yml:3: live line 'restart: x\\u2028    image: attacker/pg:16' {UNREAD}",
            "docker-compose.yml:4: live line '# note\\u2029image: ",
            "docker-compose.yml:5: live line 'labels: [a\\x85]' ",
        ),
        3,
    ),
    (
        "key spellings a YAML parser reads as the key: node properties, '?' keys, an escaped key",
        {"ci.yml": '- &a uses: x@v1\n!!str image: y\n? uses\n: x\n? image\n: y\n"u\\x73es": x\n'},
        NS,
        (
            f"ci.yml:1: live line '- &a uses: x@v1' {UNREAD}",
            f"ci.yml:2: live line '!!str image: y' {UNREAD}",
            f"ci.yml:3: live line '? uses' {UNREAD}",
            f"ci.yml:4: live line ': x' {UNREAD}",
            f"ci.yml:5: live line '? image' {UNREAD}",
            f"ci.yml:6: live line ': y' {UNREAD}",
            "ci.yml:7: live line '\"u\\\\x73es\": x' ",
        ),
        7,
    ),
    (
        "first-party is the namespace plus '/': a sibling, another path on its host, a Docker Hub prefix",
        compose(f"{NS[0]}-other/app:1.0", "registry.example/other/app:1.0", f"docker.io/{NS[0]}/app:1.0"),
        NS,
        (
            f"docker-compose.yml:3: image reference '{NS[0]}-other/app:1.0' {UNPINNED}",
            f"docker-compose.yml:5: image reference 'registry.example/other/app:1.0' {UNPINNED}",
            f"docker-compose.yml:7: image reference 'docker.io/{NS[0]}/app:1.0' {UNPINNED} "
            f"'docker.io/{NS[0]}/app:<tag>@sha256:<64 hex>'",
        ),
        3,
    ),
    (
        "a BOM before a key on line 1 is stripped",
        {"docker-compose.yml": "\ufeffimage: postgres:18.6\n"},
        NS,
        (f"docker-compose.yml:1: image reference 'postgres:18.6' {UNPINNED}",),
        1,
    ),
    (
        "an absolute-URL action",
        steps(f"- uses: https://github.com/{CHECKOUT} # v7.0.1"),
        NS,
        (f"ci.yml:4: action reference 'https://github.com/{CHECKOUT}' {URL}",),
        1,
    ),
    (
        "an inline Dockerfile fails, as does a dockerfile: that leads out of the repository",
        {
            "docker-compose.yml": (
                "services:\n"
                "  app:\n"
                "    build:\n"
                "      dockerfile_inline: |\n"
                "        FROM alpine:3\n"
                "  web:\n"
                "    build:\n"
                "      dockerfile: ../../elsewhere/Dockerfile\n"
            )
        },
        NS,
        (
            f"docker-compose.yml:4: live line 'dockerfile_inline: |' {UNREAD}",
            "docker-compose.yml:8: dockerfile '../../elsewhere/Dockerfile' is not a path inside the repository",
        ),
        2,
    ),
    (
        "# syntax= is an image reference; # escape= fails; # check= is left alone",
        {
            "Dockerfile": (
                "# syntax=docker/dockerfile:1\n"
                "# escape=`\n"
                "# check=skip=all\n"
                f"FROM alpine:3.20{DIGEST}\n"
            ),
            "b/Dockerfile.pinned": f"# syntax=docker/dockerfile:1.10{DIGEST}\nFROM scratch\n",
        },
        NS,
        (
            f"Dockerfile:1: image reference 'docker/dockerfile:1' {UNPINNED}",
            f"Dockerfile:2: live line '# escape=`' {UNREAD}",
        ),
        2,
    ),
    (
        "a container: whose value is on the next line, behind a comment or an alias, fails",
        {
            "ci.yml": (
                "jobs:\n"
                "  a:\n"
                "    container:\n"
                "      node:22\n"
                "  b:\n"
                "    container:  # the image follows\n"
                "      node:22\n"
                "  c:\n"
                "    container:\n"
                "      *image\n"
                "  d:\n"
                "    container: &job\n"
                f"      image: node:22{DIGEST}\n"
            )
        },
        NS,
        (
            f"ci.yml:4: live line 'node:22' {UNREAD}",
            f"ci.yml:7: live line 'node:22' {UNREAD}",
            f"ci.yml:10: live line '*image' {UNREAD}",
        ),
        3,
    ),
    (
        "a pin-key value continued on a deeper line fails; a sibling key at the same column does not",
        {
            "ci.yml": (
                "jobs:\n"
                "  a:\n"
                "    steps:\n"
                f"      - uses: {CHECKOUT} # v7.0.1\n"
                "        with:\n"
                "          x: 1\n"
                "      - uses: actions/checkout\n"
                f"          @{SHA} # v7.0.1\n"
            )
        },
        NS,
        (f"ci.yml:7: action reference 'actions/checkout' {NOT_SHA}", f"ci.yml:8: live line '@{SHA} # v7.0.1' {UNREAD}"),
        2,
    ),
    (
        "key positions holding '?', ':', an alias or a tag fail, as does a nested sequence item",
        {
            "compose.yaml": (
                "x-base:\n"
                "  ? db\n"
                "  : image: postgres:18\n"
                "  web:\n"
                "    *key : nginx:1\n"
                "  api:\n"
                "    !t name: nginx:1\n"
            ),
            "ci.yml": "jobs:\n  a:\n    steps:\n      - - uses: actions/checkout@v4\n      - ? |-\n          uses\n",
        },
        NS,
        (
            f"compose.yaml:2: live line '? db' {UNREAD}",
            f"compose.yaml:3: live line ': image: postgres:18' {UNREAD}",
            f"compose.yaml:5: live line '*key : nginx:1' {UNREAD}",
            f"compose.yaml:7: live line '!t name: nginx:1' {UNREAD}",
            f"ci.yml:4: live line '- - uses: actions/checkout@v4' {UNREAD}",
            f"ci.yml:5: live line '- ? |-' {UNREAD}",
        ),
        6,
    ),
    (
        "a block scalar's content is not structure: shell lines shaped like keys pass",
        {
            "ci.yml": (
                "jobs:\n"
                "  a:\n"
                "    steps:\n"
                "      - run: |\n"
                '          : "${TOKEN:?set TOKEN}"\n'
                "          ? x\n"
                "          echo *a : b\n"
                "        env:\n"
                "          A: 1\n"
                "      - run: |\n"
                "        ? uses\n"
            )
        },
        NS,
        (f"ci.yml:11: live line '? uses' {UNREAD}",),
        1,
    ),
    (
        "a service's scalar value is an image; an alias, a flow value or a value on the next line fails",
        {
            "ci.yml": (
                "jobs:\n"
                "  a:\n"
                "    services:\n"
                "      db: postgres:18\n"
                f"      cache: redis:7{DIGEST}\n"
                "      mq: *broker\n"
                "      web:\n"
                "        nginx:1\n"
                "    steps: []\n"
                "  b:\n"
                "    services: {db: postgres:18}\n"
            ),
            "compose.yaml": (
                "x-common: &common\n"
                "  restart: always\n"
                "services:\n"
                "  db:\n"
                "    <<: *common\n"
                f"    image: postgres:18{DIGEST}\n"
                "volumes:\n"
                "  data:\n"
            ),
        },
        NS,
        (
            f"ci.yml:4: image reference 'postgres:18' {UNPINNED}",
            f"ci.yml:6: live line 'mq: *broker' {UNREAD}",
            f"ci.yml:8: live line 'nginx:1' {UNREAD}",
            f"ci.yml:11: live line 'services: {{db: postgres:18}}' {UNREAD}",
        ),
        4,
    ),
    (
        "compose BUILDKIT_SYNTAX and additional_contexts fail in every shape",
        {
            "compose.yaml": (
                "services:\n"
                "  a:\n"
                "    build:\n"
                "      args:\n"
                "        BUILDKIT_SYNTAX: docker/dockerfile:1\n"
                "  b:\n"
                "    build:\n"
                "      args:\n"
                "        - BUILDKIT_SYNTAX=docker/dockerfile:1\n"
                "      additional_contexts:\n"
                "        base: docker-image://alpine:3\n"
            )
        },
        NS,
        (
            f"compose.yaml:5: live line 'BUILDKIT_SYNTAX: docker/dockerfile:1' {UNREAD}",
            f"compose.yaml:9: live line '- BUILDKIT_SYNTAX=docker/dockerfile:1' {UNREAD}",
            f"compose.yaml:10: live line 'additional_contexts:' {UNREAD}",
        ),
        3,
    ),
    (
        "a compose dockerfile: must name a file the Dockerfile family reads",
        {
            "compose.yaml": (
                "services:\n"
                "  a:\n"
                "    build:\n"
                "      dockerfile: docker/app.Dockerfile\n"
                "  b:\n"
                "    build:\n"
                "      dockerfile: build/recipe.txt\n"
                "  c:\n"
                "    build:\n"
                "      dockerfile: ${DOCKERFILE}\n"
            )
        },
        NS,
        (
            "compose.yaml:7: dockerfile 'build/recipe.txt' is not a path inside the repository named as a Dockerfile",
            "compose.yaml:10: dockerfile '${DOCKERFILE}'",
        ),
        2,
    ),
    (
        "a ./ action needs its action file or workflow among the files read",
        {
            "ci.yml": (
                "steps:\n"
                "  - uses: ./tools/lint\n"
                "  - uses: ./tools/build/\n"
                "  - uses: ./.github/workflows/reuse.yml\n"
                "  - uses: ./tools/missing\n"
                "  - uses: ./tools/../../outside\n"
            ),
            "tools/lint/action.yml": f"runs:\n  using: docker\n  image: docker://alpine:3.20{DIGEST}\n",
            "tools/build/action.yaml": "runs:\n  using: docker\n  image: build/Containerfile\n",
            "tools/build/build/Containerfile": f"FROM alpine:3.20{DIGEST}\n",
            ".github/workflows/reuse.yml": "on: workflow_call\n",
        },
        NS,
        (
            "ci.yml:5: local action './tools/missing' names no tools/missing/action.yml or tools/missing/action.yaml",
            "ci.yml:6: local action './tools/../../outside' names no ../outside/action.yml",
        ),
        2,
    ),
    (
        "a Docker container action's relative Dockerfile passes only in an action file; docker:// is an image",
        {
            "tools/x/action.yml": "runs:\n  using: docker\n  image: Dockerfile\n",
            "tools/x/Dockerfile": f"FROM alpine:3.20{DIGEST}\n",
            "tools/y/action.yml": "runs:\n  using: docker\n  image: docker://alpine:3.20\n",
            "ci.yml": "jobs:\n  a:\n    container: Dockerfile\n",
        },
        NS,
        (
            f"ci.yml:3: image reference 'Dockerfile' {UNPARSED}",
            f"tools/y/action.yml:3: image reference 'alpine:3.20' {UNPINNED}",
        ),
        2,
    ),
    (
        "a file is read by its family: a workflow named Dockerfile.*.yml is YAML",
        {".github/workflows/Dockerfile.ci.yml": "jobs:\n  a:\n    container: node:22\n"},
        NS,
        (f".github/workflows/Dockerfile.ci.yml:3: image reference 'node:22' {UNPINNED}",),
        1,
    ),
    (
        "a #! first line keeps the directive block open; other frontends and unknown words fail",
        {
            "a/Dockerfile": "#!/usr/bin/env -S docker build -f\n# syntax=docker/dockerfile:1\nFROM scratch\n",
            "b/Dockerfile": "// syntax=docker/dockerfile:1\nFROM scratch\n",
            "c/Dockerfile": '{"syntax": "docker/dockerfile:1"}\n',
            "d/Dockerfile": "FROM scratch\nFETCH alpine:3\n",
        },
        NS,
        (
            f"a/Dockerfile:2: image reference 'docker/dockerfile:1' {UNPINNED}",
            f"b/Dockerfile:1: live line '// syntax=docker/dockerfile:1' {UNREAD}",
            f"c/Dockerfile:1: live line '{{\"syntax\": \"docker/dockerfile:1\"}}' {UNREAD}",
            f"d/Dockerfile:2: live line 'FETCH alpine:3' {UNREAD}",
        ),
        4,
    ),
    (
        "COPY --from= and a --mount from= are read on the joined logical line",
        {
            "Dockerfile": (
                "FROM scratch\n"
                "COPY --fr\\\n"
                "om=alpine:3 /a /a\n"
                "RUN --mount=type=bind,fr\\\n"
                "# a comment inside the continuation\n"
                "\n"
                "om=alpine:3,target=/x true\n"
            )
        },
        NS,
        (
            f"Dockerfile:2: image reference 'alpine:3' {UNPINNED}",
            f"Dockerfile:4: live line 'RUN --mount=type=bind,from=alpine:3,target=/x true' {UNREAD}",
        ),
        2,
    ),
    (
        "a first-party image is exempt in FROM, COPY --from= and # syntax=",
        {
            "Dockerfile": (
                f"# syntax={NS[0]}/frontend:1\n"
                f"FROM {NS[0]}/base:${{REVISION}} AS build\n"
                f"COPY --from={NS[0]}/tools:2 /t /t\n"
            )
        },
        NS,
        (),
        0,
    ),
    (
        "a quoted scalar left open fails, and its continuation lines cannot fake a block scalar",
        {
            "ci.yml": (
                "jobs:\n"
                "  a:\n"
                "    env:\n"
                '      X: "q\n'
                " k: |\n"
                '"\n'
                "    container:\n"
                "      node:22\n"
            )
        },
        NS,
        (f"ci.yml:4: live line 'X: \"q' {UNREAD}", f"ci.yml:8: live line 'node:22' {UNREAD}"),
        2,
    ),
    (
        "a flow mapping left open fails, and its continuation lines cannot fake a block scalar",
        {"ci.yml": "jobs:\n  a:\n    env: {X: [\n k: |\n]}\n    container:\n      node:22\n"},
        NS,
        (f"ci.yml:3: live line 'env: {{X: [' {UNREAD}", f"ci.yml:7: live line 'node:22' {UNREAD}"),
        2,
    ),
    (
        "a quoted scalar's continuation lines cannot close services:",
        {
            "compose.yaml": (
                "services:\n"
                "  web:\n"
                "    environment:\n"
                '      X: "a\n'
                'x: "\n'
                "  db: postgres:18\n"
            )
        },
        NS,
        (f"compose.yaml:4: live line 'X: \"a' {UNREAD}", f"compose.yaml:6: image reference 'postgres:18' {UNPINNED}"),
        2,
    ),
    (
        "a flow sequence of scalars over several lines passes; one holding a key, an alias or an escape fails",
        {
            "compose.yaml": (
                "services:\n"
                "  db:\n"
                "    healthcheck:\n"
                "      test:\n"
                "        [\n"
                '          "CMD-SHELL",\n'
                '          "pg_isready || exit 1",\n'
                "        ]\n"
                f"    image: postgres:18{DIGEST}\n"
                "x-a:\n"
                "  [\n"
                "    image: postgres:18,\n"
                "  ]\n"
                "x-b:\n"
                "  [\n"
                '    "a":b,\n'
                "    *c,\n"
                '    "d\\te",\n'
                "  ]\n"
            )
        },
        NS,
        (f"compose.yaml:11: live line '[' {UNREAD}", f"compose.yaml:15: live line '[' {UNREAD}"),
        2,
    ),
    (
        "a services key in any spelling but a plain services: line fails",
        {
            "a/compose.yaml": '"services":\n  db: postgres:18\n',
            "b/compose.yaml": "'services':\n  db: postgres:18\n",
            "c/compose.yaml": "services :\n  db: postgres:18\n",
            "d/compose.yaml": "&s services:\n  db: postgres:18\n",
            "e/compose.yaml": "x: {a: 1, services: {db: postgres:18}}\n",
        },
        NS,
        (
            f"a/compose.yaml:1: live line '\"services\":' {UNREAD}",
            f"b/compose.yaml:1: live line \"'services':\" {UNREAD}",
            f"c/compose.yaml:1: live line 'services :' {UNREAD}",
            f"d/compose.yaml:1: live line '&s services:' {UNREAD}",
            f"e/compose.yaml:1: live line 'x: {{a: 1, services: {{db: postgres:18}}}}' {UNREAD}",
        ),
        5,
    ),
    (
        "a backslash escape in a double-quoted scalar, and a build argument named by a variable, fail",
        {
            "compose.yaml": (
                "services:\n"
                "  a:\n"
                "    build:\n"
                "      args:\n"
                '        "BUILDKIT_\\x53YNTAX": docker/dockerfile:1\n'
                "        - ${NAME}=docker/dockerfile:1\n"
                '        - "${OTHER:-X}"\n'
                "        - PLAIN=${fine}\n"
                "  b:\n"
                "    build:\n"
                '      args: ["${NAME}=docker/dockerfile:1"]\n'
                "  c:\n"
                "    build:\n"
                "      args: *shared\n"
            )
        },
        NS,
        (
            f"compose.yaml:5: live line '\"BUILDKIT_\\\\x53YNTAX\": docker/dockerfile:1' {UNREAD}",
            f"compose.yaml:6: live line '- ${{NAME}}=docker/dockerfile:1' {UNREAD}",
            f"compose.yaml:7: live line '- \"${{OTHER:-X}}\"' {UNREAD}",
            f"compose.yaml:11: live line 'args: [\"${{NAME}}=docker/dockerfile:1\"]' {UNREAD}",
            f"compose.yaml:14: live line 'args: *shared' {UNREAD}",
        ),
        5,
    ),
    (
        "a dockerfile: or action Dockerfile must be a Dockerfile inside the repository; an action's must be listed",
        {
            "compose.yaml": (
                "services:\n"
                "  a:\n"
                "    build:\n"
                "      dockerfile: Dockerfile.yml\n"
                "  b:\n"
                "    build:\n"
                "      dockerfile: /etc/Dockerfile\n"
                "  c:\n"
                "    build:\n"
                "      dockerfile: ../Dockerfile\n"
            ),
            "tools/x/action.yml": "runs:\n  using: docker\n  image: Dockerfile\n",
            "tools/y/action.yml": "runs:\n  using: docker\n  image: ../../../Dockerfile\n",
            "tools/z/action.yml": "runs:\n  using: docker\n  image: ../shared/Dockerfile\n",
            "tools/shared/Dockerfile": f"FROM alpine:3.20{DIGEST}\n",
        },
        NS,
        (
            "compose.yaml:4: dockerfile 'Dockerfile.yml' is not a path inside the repository named as a Dockerfile",
            "compose.yaml:7: dockerfile '/etc/Dockerfile' is not a path inside the repository",
            "compose.yaml:10: dockerfile '../Dockerfile' is not a path inside the repository",
            "tools/x/action.yml:3: image 'Dockerfile' is not a Dockerfile that git lists",
            "tools/y/action.yml:3: image '../../../Dockerfile' is not a Dockerfile that git lists",
        ),
        5,
    ),
    (
        "compose include: and extends: must name compose files that git lists",
        {
            "compose.yaml": (
                "include:\n"
                "  - base/compose.yaml\n"
                "  - path: base/compose.yaml\n"
                "  - path:\n"
                "      - base/compose.yaml\n"
                "      - missing.yaml\n"
                "  - oci://registry.example/stack:1\n"
                "services:\n"
                "  a:\n"
                "    extends:\n"
                "      file: base/compose.yaml\n"
                "      service: base\n"
                "  b:\n"
                "    extends:\n"
                "      file: common.yaml\n"
                "      service: base\n"
                "  c:\n"
                "    extends: a\n"
                "  d:\n"
                "    extends: {file: common.yaml, service: base}\n"
            ),
            "base/compose.yaml": f"services:\n  base:\n    image: alpine:3.20{DIGEST}\n",
            "other/compose.yaml": "include: [../compose.yaml]\n",
        },
        NS,
        (
            "compose.yaml:6: include file 'missing.yaml' is not a compose file that git lists",
            "compose.yaml:7: include file 'oci://registry.example/stack:1' is not a compose file",
            "compose.yaml:15: extends file 'common.yaml' is not a compose file that git lists",
            f"compose.yaml:20: live line 'extends: {{file: common.yaml, service: base}}' {UNREAD}",
            f"other/compose.yaml:1: live line 'include: [../compose.yaml]' {UNREAD}",
        ),
        5,
    ),
    (
        "an explicit indentation indicator sets the block scalar's content indent",
        {
            "ci.yml": (
                "jobs:\n"
                "  a:\n"
                "    steps:\n"
                "      - run: |2\n"
                "              echo deeper first\n"
                "          ? content at the indicated indent\n"
                "      - run: |4\n"
                "          ? uses\n"
            )
        },
        NS,
        (f"ci.yml:8: live line '? uses' {UNREAD}",),
        1,
    ),
    (
        "a lone backslash at the end of a Dockerfile leaves an empty logical line, which fails",
        {"Dockerfile": "FROM scratch\n\\"},
        NS,
        (f"Dockerfile:2: live line '' {UNREAD}",),
        1,
    ),
)


def main() -> None:
    fails = 0
    for label, files, first_party, expected, count in ROWS:
        found = [str(violation) for violation in check_files(files, first_party)]
        rendered = "\n".join(found)
        if all(text in rendered for text in expected) and len(found) == count:
            print(f"PASS corpus: {label}")
        else:
            fails += 1
            print(f"FAIL corpus: {label}: want {count} violation(s) containing {expected!r}, got:")
            print(rendered or "(none)")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
