#!/usr/bin/env bash
# Tests for scripts/check_pins.py: per case, a fresh temp git repository whose
# committed files (and, for some cases, untracked or ignored ones) the check
# reads as a project; then the table of tests/check_pins_corpus.py over its
# pure part. No network. Prints PASS/FAIL per case.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
check=$root/scripts/check_pins.py
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# shellcheck disable=SC2046 # one argument per variable name
unset $(git rev-parse --local-env-vars)
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 # no signing, no hooks from the user
export GIT_AUTHOR_NAME=devkit GIT_AUTHOR_EMAIL=devkit@example.invalid
export GIT_COMMITTER_NAME=devkit GIT_COMMITTER_EMAIL=devkit@example.invalid
repo=$work/repo
fails=0

sha=3d3c42e5aac5ba805825da76410c181273ba90b1
digest=@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef

# put FILE CONTENT...: write FILE (a line per CONTENT) into the repo, uncommitted
put() {
  mkdir -p "$(dirname "$repo/$1")"
  printf '%s\n' "${@:2}" >"$repo/$1"
}

# project FILE CONTENT...: a fresh repo with FILE committed (no FILE when none)
project() {
  rm -rf "$repo"
  git init -q -b main "$repo"
  [[ $# == 0 ]] || put "$@"
  git -C "$repo" add -A
  git -C "$repo" commit -q --allow-empty -m case
}

# step LINE...: a fresh repo whose one workflow's steps are LINE... (from line 4)
step() {
  local lines=() line
  for line in "$@"; do lines+=("      $line"); done
  project .gitea/workflows/ci.yml "jobs:" "  a:" "    steps:" "${lines[@]}"
}

# image VALUE: a fresh repo whose compose.yaml names image VALUE on line 3
image() { project compose.yaml "services:" "  db:" "    image: $1"; }

# dockerfile LINE...: a fresh repo whose Dockerfile holds LINE...
dockerfile() { project Dockerfile "$@"; }

# expect LABEL WANT-STATUS WANT-TEXT...: run the check on the repo; the
# output must contain every WANT-TEXT and no Python traceback
expect() {
  local label=$1 want=$2 out rc=0 text ok=true
  shift 2
  out=$(PROJECT_ROOT=$repo python3 "$check" 2>&1) || rc=$?
  for text in "$@"; do [[ $out == *"$text"* ]] || ok=false; done
  if [[ $rc == "$want" && $ok == true && $out != *Traceback* ]]; then
    echo "PASS $label"
  else
    echo "FAIL $label: exit $rc, want $want and each of [$*] in:"
    printf '%s\n' "$out"
    fails=$((fails + 1))
  fi
}
no_digest="it carries no digest"
not_sha="is not pinned to a full commit SHA"
not_exact="where an exact '# vX.Y.Z' is required"
unread="in a shape this check cannot read"
unparsed="does not parse as"

# Actions.
step "- uses: actions/checkout@$sha # v7.0.1"
expect "an action pinned to a SHA with '# v7.0.1' passes" 0 "1 workflow,"
step "- uses: actions/checkout@v4"
expect "an action on a tag fails" 1 "ci.yml:4: action reference 'actions/checkout@v4' $not_sha"
step "- uses: actions/checkout@${sha:0:7} # v7.0.1"
expect "an action on a short SHA fails" 1 "$not_sha"
step "- uses: actions/checkout@${sha^^} # v7.0.1"
expect "an action on an uppercase SHA fails" 1 "$not_sha"
step "- uses: actions/checkout@$sha"
expect "a SHA without a version comment fails" 1 "carries no comment $not_exact"
step "- uses: actions/checkout@$sha # v7"
expect "a SHA with a floating '# v7' fails" 1 "carries '# v7' $not_exact"
step "- uses: ./x"
put x/action.yml "runs:" "  using: composite" "  steps: []"
expect "a local ./ action whose action.yml is listed passes" 0 "1 workflow, 1 action,"
step "- uses: ./x"
expect "a local ./ action without an action file fails" 1 "local action './x' names no x/action.yml or x/action.yaml"
step "- uses: https://example.com/actions/checkout@$sha # v7.0.1"
expect "an absolute-URL action fails" 1 "is an absolute URL"
step "- uses: docker://alpine:3.20"
expect "a docker:// action without a digest fails" 1 "image reference 'alpine:3.20' is not pinned" "$no_digest"
step "- uses: docker://alpine:3.20$digest"
expect "a docker:// action with a digest passes" 0 "1 workflow,"
step "- uses: owner/repo/sub@$sha # v1.0.0"
expect "an action in a repository subdirectory passes" 0 "1 workflow,"

# YAML shapes the line reader cannot read, and lines it must not read.
step "- {uses: actions/checkout@$sha}"
expect "a flow mapping fails" 1 "ci.yml:4: live line" "$unread"
step "- \"uses\": actions/checkout@$sha # v7.0.1"
expect "a quoted key fails" 1 "$unread"
project compose.yaml "services:" "  db:" "    image:" "      postgres:18$digest"
expect "a value on the next line fails" 1 "compose.yaml:3: live line 'image:'" "$unread"
step "- uses: actions/checkout" "    @$sha # v7.0.1"
expect "a value continued on a deeper line fails" 1 "ci.yml:5: live line '@$sha # v7.0.1'" "$unread"
project .gitea/workflows/ci.yml "jobs:" "  a:" "    container:" "      node:22"
expect "a container: whose value is on the next line fails" 1 "ci.yml:4: live line 'node:22'" "$unread"
project .gitea/workflows/ci.yml "jobs:" "  a:" "    container:  # the image" "      node:22"
expect "a container: whose value follows a comment fails" 1 "ci.yml:4: live line 'node:22'" "$unread"
project .gitea/workflows/ci.yml "jobs:" "  a:" "    container:" "      *image"
expect "a container: whose value is an alias on the next line fails" 1 "ci.yml:4: live line '*image'" "$unread"
project compose.yaml "x-base:" "  ? db" "  : image: postgres:18"
expect "an explicit '?' key and a ':' value indicator fail" 1 "compose.yaml:2: live line '? db'" \
  "compose.yaml:3: live line ': image: postgres:18'"
project compose.yaml "x-base:" "  *key : postgres:18"
expect "an alias used as a key fails" 1 "compose.yaml:2: live line '*key : postgres:18'" "$unread"
project compose.yaml "x-base:" "  !t name: postgres:18"
expect "a tagged key fails" 1 "compose.yaml:2: live line '!t name: postgres:18'" "$unread"
step "- - uses: actions/checkout@v4"
expect "a nested sequence item fails" 1 "ci.yml:4: live line '- - uses: actions/checkout@v4'" "$unread"
# shellcheck disable=SC2016 # a literal shell line inside the workflow
step "- run: |" '    : "${TOKEN:?set TOKEN}"' "    ? x"
expect "shell lines shaped like keys inside run: | pass" 0 "1 workflow,"
project .github/workflows/ci.yml "jobs:" "  a:" "    services:" "      db: postgres:18"
expect "a workflow service's scalar image is read" 1 "ci.yml:4: image reference 'postgres:18'" "$no_digest"
project .github/workflows/ci.yml "jobs:" "  a:" "    services:" "      db: *postgres"
expect "a workflow service that is an alias fails" 1 "ci.yml:4: live line 'db: *postgres'" "$unread"
project compose.yaml "services:" "  a:" "    build:" "      args:" "        - BUILDKIT_SYNTAX=docker/dockerfile:1"
expect "a compose BUILDKIT_SYNTAX build argument fails" 1 "compose.yaml:5: live line" "$unread"
project compose.yaml "services:" "  a:" "    build:" "      additional_contexts:" "        base: docker-image://alpine:3"
expect "compose additional_contexts fails" 1 "compose.yaml:4: live line 'additional_contexts:'" "$unread"
project compose.yaml "services:" "  a:" "    build:" "      dockerfile: build/recipe.txt"
expect "a compose dockerfile: outside the Dockerfile family fails" 1 \
  "compose.yaml:4: dockerfile 'build/recipe.txt' is not a path inside the repository named as a Dockerfile"
project compose.yaml "services:" "  a:" "    build:" "      dockerfile: docker/app.Dockerfile"
expect "a compose dockerfile: in the Dockerfile family passes" 0 "1 compose file,"
project .gitea/workflows/ci.yml "jobs:" "  a:" "    env:" '      X: "q' " k: |" '"' "    container:" "      node:22"
expect "a quoted value left open fails and cannot fake a block scalar" 1 "ci.yml:4: live line 'X: \"q'" \
  "ci.yml:8: live line 'node:22'"
project .gitea/workflows/ci.yml "jobs:" "  a:" "    env: {X: [" " k: |" "]}" "    container:" "      node:22"
expect "a flow mapping left open fails and cannot fake a block scalar" 1 "ci.yml:3: live line 'env: {X: ['" \
  "ci.yml:7: live line 'node:22'"
project compose.yaml "services:" "  web:" "    environment:" '      X: "a' 'x: "' "  db: postgres:18"
expect "a quoted value's continuation cannot close services:" 1 "compose.yaml:4: live line" \
  "compose.yaml:6: image reference 'postgres:18'"
project compose.yaml "services:" "  db:" "    healthcheck:" "      test:" "        [" '          "CMD-SHELL",' \
  '          "pg_isready || exit 1",' "        ]" "    image: postgres:18$digest"
expect "a flow sequence of scalars over several lines passes" 0 "1 compose file,"
project compose.yaml "x-a:" "  [" "    image: postgres:18," "  ]"
expect "a flow sequence over several lines holding a key fails" 1 "compose.yaml:2: live line '['" "$unread"
for spelling in '"services":' "'services':" "services :" "&s services:"; do
  project compose.yaml "$spelling" "  db: postgres:18"
  expect "services spelled $spelling fails" 1 "compose.yaml:1: live line" "$unread"
done
project compose.yaml "x: {a: 1, services: {db: postgres:18}}"
expect "a services key inside a flow mapping fails" 1 "compose.yaml:1: live line" "$unread"
project compose.yaml "services:" "  a:" "    build:" "      args:" '        "BUILDKIT_\x53YNTAX": docker/dockerfile:1'
expect "a backslash escape in a double-quoted key fails" 1 "compose.yaml:5: live line" "$unread"
# shellcheck disable=SC2016 # a literal compose interpolation
project compose.yaml "services:" "  a:" "    build:" "      args:" '        - ${NAME}=docker/dockerfile:1'
expect "a list-form build argument named by a variable fails" 1 "compose.yaml:5: live line" "$unread"
project compose.yaml "services:" "  a:" "    build:" "      dockerfile: Dockerfile.yml"
expect "a compose dockerfile: with a YAML suffix fails" 1 "dockerfile 'Dockerfile.yml' is not a path inside the repository"
project compose.yaml "services:" "  a:" "    build:" "      dockerfile: ../Dockerfile"
expect "a compose dockerfile: leading out of the repository fails" 1 "dockerfile '../Dockerfile' is not a path inside"
project compose.yaml "include:" "  - base/compose.yaml" "services: {}"
put base/compose.yaml "services: {}"
expect "an include: of a listed compose file passes" 0 "2 compose files"
project compose.yaml "include:" "  - missing.yaml" "services: {}"
expect "an include: of a file git does not list fails" 1 "include file 'missing.yaml' is not a compose file that git lists"
project compose.yaml "services:" "  a:" "    extends:" "      file: common.yaml" "      service: base"
expect "an extends: file git does not list fails" 1 "extends file 'common.yaml' is not a compose file that git lists"
project compose.yaml "services:" "  a:" "    extends: {file: common.yaml, service: base}"
expect "a flow extends: fails" 1 "compose.yaml:3: live line" "$unread"
step "- run: |2" "        echo deeper first" "    ? content at the indicated indent"
expect "an explicit indentation indicator sets the content indent" 0 "1 workflow,"
project compose.yaml "services:" "  app:" "    build:" "      dockerfile_inline: |" "        FROM alpine:3"
expect "an inline Dockerfile fails" 1 "compose.yaml:4: live line 'dockerfile_inline: |'" "$unread"
project compose.yaml "services:" $'  db:\xe2\x80\xa8    image: postgres:18' # U+2028 in UTF-8
expect "a line holding U+2028 fails" 1 "compose.yaml:2: live line" "$unread"
step '- run: echo "image: x"' "# - uses: actions/checkout@v4"
expect "a key inside a string and a commented key are not read" 0 "1 workflow,"

# Images.
image "postgres:18.6$digest"
expect "an image with a tag and a digest passes" 0 "1 compose file,"
image "postgres:18.6"
expect "an image with a tag only fails" 1 "compose.yaml:3: image reference 'postgres:18.6'" "$no_digest"
image "postgres$digest"
expect "an image with a digest only fails" 1 "it carries no tag"
image "acme/app:\${REVISION:-1}"
expect "a first-party image with a variable tag fails without [pins]" 1 "$unparsed"
put devkit.toml '[pins]' 'first-party = ["acme"]'
expect "a first-party image with a variable tag passes when acme is declared" 0 "1 compose file,"
image "\${NS:-acme}/app:1"
put devkit.toml '[pins]' 'first-party = ["acme"]'
expect "a variable in the repository part fails even with first-party" 1 "$unparsed"
image "docker.io/library/postgres:18.6"
expect "docker.io/library/postgres is read as postgres" 1 "'postgres:<tag>@sha256:<64 hex>'"
image "acme/app:1"
put devkit.toml '[pins]' 'first-party = ["docker.io/acme"]'
expect "first-party docker.io/acme covers acme/app" 0 "1 compose file,"
image "docker.io/acme/app:1"
put devkit.toml '[pins]' 'first-party = ["acme"]'
expect "first-party acme covers docker.io/acme/app" 0 "1 compose file,"
image "docker.io/ghcr.io/acme/app:1"
put devkit.toml '[pins]' 'first-party = ["ghcr.io/acme"]'
expect "docker.io/ghcr.io/acme/app is not under ghcr.io/acme" 1 "$no_digest"
project .gitea/workflows/ci.yml "jobs:" "  a:" "    container: node:22"
expect "a scalar container: without a digest fails" 1 "ci.yml:3: image reference 'node:22'" "$no_digest"
project .gitea/workflows/ci.yml "jobs:" "  a:" "    container:" "      image: node:22"
expect "the image: of a mapping-form container: is read" 1 "ci.yml:4: image reference 'node:22'"
project .github/workflows/ci.yml "jobs:" "  a:" "    services:" "      db:" "        image: postgres:18"
expect "a workflow's services: images are read" 1 "ci.yml:5: image reference 'postgres:18'"

# Dockerfiles.
dockerfile "FROM alpine:3.20$digest"
expect "a pinned FROM passes" 0 "1 Dockerfile checked"
# shellcheck disable=SC2016 # a literal Dockerfile variable
dockerfile 'FROM --platform=$BUILDPLATFORM alpine:3.20'"$digest"
expect "a FROM with --platform=\$X passes" 0 "1 Dockerfile checked"
dockerfile "FROM alpine:3.20$digest AS build" "FROM build" "COPY --from=build /a /a" "COPY --from=0 /b /b"
expect "stage references pass" 0 "1 Dockerfile checked"
dockerfile "FROM scratch" "COPY --from=alpine:3 /a /a"
expect "COPY --from= an image without a digest fails" 1 "Dockerfile:2: image reference 'alpine:3'" "$no_digest"
dockerfile "FROM scratch"
expect "FROM scratch passes" 0 "1 Dockerfile checked"
# shellcheck disable=SC2016 # a literal Dockerfile variable
dockerfile 'FROM ${BASE}'
expect "FROM \${BASE} fails" 1 "Dockerfile:1: image reference '\${BASE}' $unparsed"
dockerfile "# syntax=docker/dockerfile:1" "FROM scratch"
expect "an unpinned # syntax= fails" 1 "Dockerfile:1: image reference 'docker/dockerfile:1'" "$no_digest"
dockerfile "# escape=\`" "FROM scratch"
expect "an # escape= directive fails" 1 "Dockerfile:1: live line" "$unread"
dockerfile "FROM scratch" "RUN <<EOF" "echo hi" "EOF"
expect "a heredoc fails" 1 "Dockerfile:2: live line 'RUN <<EOF'" "$unread"
dockerfile "FROM \\" "  alpine:3.20$digest"
expect "a continued FROM fails" 1 "Dockerfile:1: live line" "$unread"
project
printf '%s\n%s' "FROM scratch" "\\" >"$repo/Dockerfile" # no newline after the backslash
expect "a lone backslash at the end of a Dockerfile fails" 1 "Dockerfile:2: live line ''" "$unread"
project Dockerfile.dockerignore "FROM alpine:3"
expect "Dockerfile.dockerignore is not read" 0 "0 Dockerfiles checked"
dockerfile "#!/usr/bin/env -S docker build -f" "# syntax=docker/dockerfile:1" "FROM scratch"
expect "a #! line keeps the directive block open" 1 "Dockerfile:2: image reference 'docker/dockerfile:1'"
dockerfile "// syntax=docker/dockerfile:1" "FROM scratch"
expect "a // frontend line fails" 1 "Dockerfile:1: live line '// syntax=docker/dockerfile:1'" "$unread"
dockerfile '{"syntax": "docker/dockerfile:1"}'
expect "a JSON frontend fails" 1 "Dockerfile:1: live line" "$unread"
dockerfile "FROM scratch" "FETCH alpine:3"
expect "a word that is no Dockerfile instruction fails" 1 "Dockerfile:2: live line 'FETCH alpine:3'" "$unread"
dockerfile "FROM scratch" "COPY --fr\\" "om=alpine:3 /a /a"
expect "COPY --from= split by a continuation is read" 1 "Dockerfile:2: image reference 'alpine:3'" "$no_digest"
dockerfile "FROM scratch" "RUN --mount=type=bind,fr\\" "# a comment" "om=alpine:3,target=/x true"
expect "a --mount from= split by a continuation fails" 1 \
  "Dockerfile:2: live line 'RUN --mount=type=bind,from=alpine:3,target=/x true'" "$unread"
put devkit.toml "[pins]" 'first-party = ["acme"]'
dockerfile "# syntax=acme/frontend:1" "FROM acme/base:2 AS build" "COPY --from=acme/tools:3 /t /t"
put devkit.toml "[pins]" 'first-party = ["acme"]'
expect "first-party images pass in # syntax=, FROM and COPY --from=" 0 "1 Dockerfile checked"
project app.Dockerfile "FROM alpine:3"
put Containerfile "FROM alpine:3"
put build/dockerfile-dev "FROM alpine:3"
put build/Dockerfile_prod "FROM alpine:3"
put build/.containerignore "FROM alpine:3"
expect "every Dockerfile spelling is read, the ignore file is not" 1 "4 Dockerfiles checked" \
  "app.Dockerfile:1:" "Containerfile:1:" "build/dockerfile-dev:1:" "build/Dockerfile_prod:1:"
project .github/workflows/Dockerfile.ci.yml "jobs:" "  a:" "    container: node:22"
expect "a workflow named Dockerfile.*.yml is read as a workflow" 1 "1 workflow," \
  ".github/workflows/Dockerfile.ci.yml:3: image reference 'node:22'"

# Discovery.
project deploy/compose.prod.yaml "services:" "  db:" "    image: postgres:18"
expect "a nested compose.prod.yaml is read" 1 "deploy/compose.prod.yaml:3:"
project .github/workflows/x.yml "    - uses: actions/checkout@v4"
expect "a .github workflow is read" 1 ".github/workflows/x.yml:1:"
project .gitea/workflows/sub/x.yaml "    - uses: actions/checkout@v4"
expect "a .gitea workflow in a subdirectory is read" 1 ".gitea/workflows/sub/x.yaml:1:"
project .gitea/actions/build/action.yml "    - uses: actions/checkout@v4"
expect "a composite action is read" 1 ".gitea/actions/build/action.yml:1:" "1 action,"
project tools/x/action.yml "runs:" "  using: docker" "  image: Dockerfile"
put tools/x/Dockerfile "FROM alpine:3.20$digest"
expect "an action.yml anywhere is read; its relative Dockerfile passes" 0 "1 action, 0 compose files, 1 Dockerfile"
project tools/x/action.yml "runs:" "  using: docker" "  image: Dockerfile"
expect "an action's Dockerfile that git does not list fails" 1 "image 'Dockerfile' is not a Dockerfile that git lists"
project tools/x/action.yml "runs:" "  using: docker" "  image: docker://alpine:3.20"
expect "a docker:// action image without a digest fails" 1 "tools/x/action.yml:3: image reference 'alpine:3.20'"
project "deploy dir/compose.yaml" "services:" "  db:" "    image: postgres:18"
put "déploy/compose.yaml" "services:" "  db:" "    image: postgres:18"
expect "paths with a space or non-ASCII are read" 1 "deploy dir/compose.yaml:3:" "déploy/compose.yaml:3:"
project
printf 'image: \xff\n' >"$repo/compose.yaml"
expect "a compose file that is not UTF-8 fails" 1 "compose.yaml:0: cannot be read (not UTF-8)"
project .gitignore "/compose.yaml"
put compose.yaml "image: postgres:18"
expect "an ignored compose file is not read" 0 "0 compose files"
project
put docker-compose.dev.yml "image: postgres:18"
expect "an untracked compose file that is not ignored is read" 1 "docker-compose.dev.yml:1:"
project
expect "a repository without such files passes" 0 \
  "reference pins: 0 workflows, 0 actions, 0 compose files, 0 Dockerfiles checked"
project compose.yaml "image: postgres:18"
rm "$repo/compose.yaml"
expect "a tracked file deleted from disk is skipped" 0 "0 compose files"
mkdir "$work/plain"
GIT_CEILING_DIRECTORIES=$work repo=$work/plain expect "a directory outside a git work tree fails" 1 \
  "ERROR: git cannot list the files in"
project elsewhere.yaml "image: postgres:18"
ln -s elsewhere.yaml "$repo/compose.yaml"
expect "a symlinked compose file fails" 1 "compose.yaml:0: is a symlink"

# devkit.toml.
project devkit.toml "[devkit]" 'version = "v0.0.0"'
expect "devkit.toml without [pins] passes" 0 "0 compose files"
project devkit.toml "[pins]" "other = 1"
expect "an unknown key under [pins] fails" 1 "ERROR: devkit.toml: unknown key(s) under [pins]: other"
project devkit.toml "[pins]" 'first-party = "acme"'
expect "a first-party string, not a list, fails" 1 "ERROR: devkit.toml: [pins] first-party must be a list"
project devkit.toml "[pins]" 'first-party = ["Acme"]'
expect "an uppercase first-party entry fails" 1 "ERROR: devkit.toml: [pins] first-party entry 'Acme'"
project devkit.toml "[pins]" 'first-party = ["acme:1"]'
expect "a first-party entry with a tag fails" 1 "ERROR: devkit.toml: [pins] first-party entry 'acme:1'"
project devkit.toml "pins = 1"
expect "pins that is not a table fails" 1 "ERROR: devkit.toml: pins must be the table [pins]"
project devkit.toml "[pins]" "first-party = [1]"
expect "a first-party entry that is not a string fails" 1 "ERROR: devkit.toml: [pins] first-party entry 1"
project devkit.toml "[pins"
expect "an invalid devkit.toml fails" 1 "ERROR: cannot read devkit.toml"

# The table of reference shapes, over the pure check.
PYTHONPATH=$root/scripts python3 "$root/tests/check_pins_corpus.py" || fails=$((fails + 1))

[[ $fails == 0 ]]
