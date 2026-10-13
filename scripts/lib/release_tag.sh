#!/bin/bash

# Sourced by tag.sh and untag.sh: what a release tag looks like, and the latest one.
# A release tag is X.Y.Z, optionally prefixed v and followed by rcN or -rcN, without leading zeros.
# TAG_RE groups: 1 prefix, 2-4 version components, 5 the rc part, 6 its spelling, 7 its number.

num='(0|[1-9][0-9]*)'
TAG_RE="^(v?)${num}\\.${num}\\.${num}((-?rc)${num})?\$"
# shellcheck disable=SC2034 # read by tag.sh, which sources this
TAG_SHAPE="X.Y.Z, optionally prefixed v and followed by rcN or -rcN (no leading zeros)"
unset num

# latest_release_tag: the highest release-shaped tag, an rc sorting before its final; none, nothing.
latest_release_tag() {
    local tag
    while IFS= read -r tag; do
        if [[ $tag =~ $TAG_RE ]]; then
            echo "$tag"
            return
        fi
    done < <(git -c versionsort.suffix=-rc -c versionsort.suffix=rc for-each-ref \
        --sort=-version:refname --format='%(refname:lstrip=2)' refs/tags)
}
