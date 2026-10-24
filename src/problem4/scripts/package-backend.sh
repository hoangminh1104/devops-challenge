#!/usr/bin/env bash
set -Eeuo pipefail
image=${1:?tested image required}
sha=${2:?full SHA required}
output=${3:?output archive required}
[[ $sha =~ ^[a-f0-9]{40}$ ]] || exit 2
here=$(cd -- "$(dirname -- "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
id=$(docker image inspect --format '{{.Id}}' "$image")
[[ $(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$id") == "$sha" ]] || exit 2
docker save --output "$tmp/image.tar" "$id"
printf '%s\n' "$sha" > "$tmp/RELEASE"
printf '%s\n' "$id" > "$tmp/IMAGE"
cp "$here/../deploy/compose.api.yaml" "$tmp/compose.api.yaml"
(cd "$tmp"; sha256sum image.tar RELEASE IMAGE compose.api.yaml) > "$tmp/SHA256SUMS"
# One gzip layer around Docker's tar: smaller than nesting gzip archives.
tar -czf "$output" -C "$tmp" image.tar RELEASE IMAGE compose.api.yaml SHA256SUMS
sha256sum "$output"
