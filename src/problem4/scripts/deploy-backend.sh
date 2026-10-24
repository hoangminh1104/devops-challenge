#!/usr/bin/env bash
set -Eeuo pipefail
# Root on the Linux host. Dependencies and /etc/ship-api.env are bootstrap-owned.
archive=${1:?archive required}
sha=${2:?release required}
[[ $sha =~ ^[a-f0-9]{40}$ ]] || exit 2
# Bootstrap-owned trusted shell configuration, shared by releases and rollback.
deploy_env=${DEPLOY_ENV_FILE:-/etc/ship-api-deploy.env}
if [[ -f $deploy_env ]]; then
  set -a
  # shellcheck disable=SC1090 # Root-only host configuration, never an artifact member.
  source "$deploy_env"
  set +a
fi
root=${APP_ROOT:-/opt/ship-api}
project=${API_PROJECT:-ship-api}
mkdir -p "$root/releases"
exec 9>"$root/deploy.lock"
flock -w "${LOCK_TIMEOUT:-480}" 9 || { echo 'Host deployment lock timed out' >&2; exit 1; }
stage=$(mktemp -d "$root/releases/.incoming.XXXXXX")
trap 'rm -rf "$stage"' EXIT
digest=$(sha256sum "$archive"); digest=${digest%% *}
if [[ -n ${ARCHIVE_SHA256:-} ]]; then [[ $digest == "$ARCHIVE_SHA256" ]] || exit 2; fi
tar -tzf "$archive" > "$stage/names"
printf '%s\n' image.tar RELEASE IMAGE compose.api.yaml SHA256SUMS > "$stage/expected"
cmp "$stage/names" "$stage/expected"
if tar -tvzf "$archive" | grep -qv '^-'; then echo 'Non-regular archive member' >&2; exit 2; fi
tar -xzf "$archive" -C "$stage" --no-same-owner --no-same-permissions
[[ $(cat "$stage/RELEASE") == "$sha" ]] || exit 2
image=$(cat "$stage/IMAGE")
[[ $image =~ ^sha256:[a-f0-9]{64}$ ]] || exit 2
# Check exactly these members, not paths supplied by a checksum file.
(cd "$stage"; sha256sum image.tar RELEASE IMAGE compose.api.yaml) > "$stage/actual"
cmp "$stage/actual" "$stage/SHA256SUMS"
target="$root/releases/$sha"
docker load --input "$stage/image.tar"
[[ $(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$image") == "$sha" ]] || exit 2
if [[ -e $target ]]; then
  [[ $(cat "$target/ARCHIVE_SHA256") == "$digest" ]] || { echo 'SHA already has different bytes' >&2; exit 2; }
else
  mkdir "$stage/metadata"
  cp "$stage/"{RELEASE,IMAGE,compose.api.yaml} "$stage/metadata/"
  printf '%s\n' "$digest" > "$stage/metadata/ARCHIVE_SHA256"
  mv "$stage/metadata" "$target"
fi
# Retained local image IDs, not mutable tags. Never compose down or start dependencies.
compose() {
  API_IMAGE=$(cat "$1/IMAGE") docker compose --project-name "$project" -f "$1/compose.api.yaml" "${@:2}"
}
healthy() {
  local directory=$1 expected container
  expected=$(cat "$directory/RELEASE")
  for ((i=0; i<${HEALTH_ATTEMPTS:-30}; i++)); do
    container=$(compose "$directory" ps -q api) || container=''
    if [[ -n $container ]] && docker exec "$container" node -e '
      fetch("http://127.0.0.1:3000/api/health", {signal: AbortSignal.timeout(2500)}).then(async r=>{
        const h=await r.json(); if(!r.ok||h.status!=="ok"||h.release!==process.argv[1]||
          h.postgres?.ok!==true||h.redis?.ok!==true) process.exit(1);
      }).catch(()=>process.exit(1))' "$expected"; then return 0; fi
    sleep "${HEALTH_DELAY:-2}"
  done
  return 1
}
point() {
  rm -f "$root/$1.next"
  ln -s "$2" "$root/$1.next"
  mv -Tf "$root/$1.next" "$root/$1"
}
previous=''
if [[ -L $root/current ]]; then previous=$(readlink -f "$root/current"); fi
# Same-SHA retries must not overwrite the last distinct known-good image.
if [[ $previous == "$target" && -L $root/previous ]]; then previous=$(readlink -f "$root/previous"); fi
rollback() {
  trap - ERR INT TERM
  echo 'Release failed; restoring previous API image' >&2
  compose "$target" logs --tail 30 api || true
  if [[ -n $previous ]]; then
    if compose "$previous" up -d --no-deps --pull never api && healthy "$previous"; then
      point current "$previous"
      echo "Previous release restored: $(cat "$previous/RELEASE")" >&2
    else
      echo 'CRITICAL: previous API did not recover; inspect host' >&2
    fi
  else
    compose "$target" stop api || true
    rm -f "$root/current"
  fi
  exit 1
}
trap rollback ERR INT TERM
compose "$target" up -d --no-deps --pull never api
healthy "$target"
if [[ -n $previous && $previous != "$target" ]]; then point previous "$previous"; fi
point current "$target"
trap - ERR INT TERM
echo "Healthy release: $sha ($image)"
