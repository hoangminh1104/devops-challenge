#!/usr/bin/env bash
# Supplemental control-flow tests. These do NOT replace tests/docker.sh.
set -Eeuo pipefail
here=$(cd -- "$(dirname -- "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin"
cp "$here/host-double/docker" "$tmp/bin/docker"
chmod +x "$tmp/bin/docker"
export PATH="$tmp/bin:$PATH" MOCK_STATE="$tmp/state" APP_ROOT="$tmp/host"
export HEALTH_ATTEMPTS=1 HEALTH_DELAY=0
mkdir "$MOCK_STATE"
# Simulate a fresh SSM shell: settings exist only in the persistent host file.
export DEPLOY_ENV_FILE="$tmp/deploy.env" EXPECT_HOST_CONFIG=yes
printf '%s\n' 'API_BIND=0.0.0.0' 'API_PORT=4300' 'API_PROJECT=custom-api' \
  'API_ENV_FILE=/etc/custom-api.env' 'DATA_NETWORK=custom-data' > "$DEPLOY_ENV_FILE"
chmod 600 "$DEPLOY_ENV_FILE"
unset API_BIND API_PORT API_PROJECT API_ENV_FILE DATA_NETWORK
good=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
next=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
bad=cccccccccccccccccccccccccccccccccccccccc
package() {
  local sha=$1
  mkdir -p "$tmp/$sha"
  printf '%s\n' "$sha" > "$tmp/$sha/RELEASE"
  printf 'sha256:%s%s\n' "$sha" "${sha:0:24}" > "$tmp/$sha/IMAGE"
  echo 'mock Docker save bytes' > "$tmp/$sha/image.tar"
  cp "$here/../deploy/compose.api.yaml" "$tmp/$sha/compose.api.yaml"
  (cd "$tmp/$sha"; sha256sum image.tar RELEASE IMAGE compose.api.yaml) > "$tmp/$sha/SHA256SUMS"
  tar -czf "$tmp/$sha.tar.gz" -C "$tmp/$sha" image.tar RELEASE IMAGE compose.api.yaml SHA256SUMS
}
deploy() { bash "$here/../scripts/deploy-backend.sh" "$tmp/$1.tar.gz" "$1"; }
must_fail() { if "$@"; then echo "Expected failure: $*" >&2; exit 1; fi; }
for sha in "$good" "$next" "$bad"; do package "$sha"; done
deploy "$good"
# No distinct previous release exists yet: a failed retry must retain its pointer.
FAIL_SHA=$good must_fail deploy "$good"
[[ $(cat "$APP_ROOT/current/RELEASE") == "$good" ]]
deploy "$next"
deploy "$next"
[[ $(cat "$APP_ROOT/previous/RELEASE") == "$good" ]]
export FAIL_SHA=$bad
must_fail deploy "$bad"
[[ $(cat "$APP_ROOT/current/RELEASE") == "$next" ]]
[[ $(wc -l < "$MOCK_STATE/config.log") -gt 4 ]]
# Failed retry of the active SHA restores its last DISTINCT known-good image.
export FAIL_SHA=$next
must_fail deploy "$next"
[[ $(cat "$APP_ROOT/current/RELEASE") == "$good" ]]
unset FAIL_SHA
export FAIL_START=$next
must_fail deploy "$next"
[[ $(cat "$APP_ROOT/current/RELEASE") == "$good" ]]
unset FAIL_START
export STALE_SHA=$next
must_fail deploy "$next"
unset STALE_SHA
[[ $(cat "$APP_ROOT/current/RELEASE") == "$good" ]]
export BAD_REDIS=$next
must_fail deploy "$next"
unset BAD_REDIS
[[ $(cat "$APP_ROOT/current/RELEASE") == "$good" ]]
export APP_ROOT="$tmp/first" FAIL_SHA=$bad
must_fail deploy "$bad"
[[ ! -L $APP_ROOT/current ]]
grep -q ' stop api$' "$MOCK_STATE/docker.log"
unset FAIL_SHA
export APP_ROOT="$tmp/host"
must_fail bash "$here/../scripts/deploy-backend.sh" "$tmp/$good.tar.gz" '../unsafe'
ARCHIVE_SHA256=bad must_fail deploy "$good"
echo changed >> "$tmp/$next/image.tar"
tar -czf "$tmp/corrupt.tar.gz" -C "$tmp/$next" image.tar RELEASE IMAGE compose.api.yaml SHA256SUMS
must_fail bash "$here/../scripts/deploy-backend.sh" "$tmp/corrupt.tar.gz" "$next"
ln -s /etc/passwd "$tmp/$next/extra"
tar -czf "$tmp/extra.tar.gz" -C "$tmp/$next" image.tar RELEASE IMAGE compose.api.yaml SHA256SUMS extra
must_fail bash "$here/../scripts/deploy-backend.sh" "$tmp/extra.tar.gz" "$next"
flock "$APP_ROOT/deploy.lock" sleep 2 &
locker=$!
sleep 0.2
LOCK_TIMEOUT=0 must_fail deploy "$good"
wait "$locker"
if grep -Eq ' down| up .*postgres| up .*redis' "$MOCK_STATE/docker.log"; then exit 1; fi
echo 'PASS: host control flow (Docker double): success, rollback, same-SHA recovery, first failure, start failure, stale identity, dependency failure, integrity, archive allowlist, lock'
