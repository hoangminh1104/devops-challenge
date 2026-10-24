#!/usr/bin/env bash
set -Eeuo pipefail
here=$(cd -- "$(dirname -- "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
tmp=$(mktemp -d)
project="p4-test-$$"
export API_PORT=${TEST_API_PORT:-18304} WEB_PORT=${TEST_WEB_PORT:-18305}
export RELEASE_SHA=${RELEASE_SHA:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}
export API_IMAGE=${API_IMAGE:-problem4-api:test-$$} FRONTEND_IMAGE="problem4-frontend:test-$$"
export CORS_ORIGIN=https://app.example.test
compose() { docker compose -p "$project" -f "$here/../compose.yaml" "$@"; }
cleanup() {
  compose logs --tail 20 > "$tmp/compose.log" 2>&1 || true
  if [[ ${KEEP_DOCKER_TEST:-0} != 1 ]]; then
    docker compose -p "$project-api" -f "$here/../deploy/compose.api.yaml" rm -sf api || true
    compose down -v --remove-orphans || true
    rm -rf "$tmp"
  else echo "Preserved $project and $tmp"; fi
}
trap cleanup EXIT
if [[ ${SKIP_BUILD:-0} != 1 ]]; then
  docker build --load -f "$here/../Dockerfile" --build-arg "RELEASE_SHA=$RELEASE_SHA" -t "$API_IMAGE" "$repo"
fi
compose build frontend
compose up -d --no-build --wait --wait-timeout 120
node "$here/http.mjs" "http://127.0.0.1:$API_PORT" "$RELEASE_SHA"
PROXY_ONLY=1 node "$here/http.mjs" "http://127.0.0.1:$WEB_PORT" "$RELEASE_SHA"
curl -fsS "http://127.0.0.1:$WEB_PORT/" | grep -q 'Problem 3 service'
[[ $(compose exec -T api id -u) != 0 ]]
compose exec -T postgres psql -U postgres -c "CREATE TABLE release_probe(value text); INSERT INTO release_probe VALUES ('survives');"
pg=$(compose ps -q postgres); redis=$(compose ps -q redis)
[[ -z $(docker port "$pg") && -z $(docker port "$redis") ]]
compose stop redis
node "$here/http.mjs" "http://127.0.0.1:$API_PORT" "$RELEASE_SHA" redis-down
compose start redis
compose stop postgres
node "$here/http.mjs" "http://127.0.0.1:$API_PORT" "$RELEASE_SHA" postgres-down
compose start postgres
compose up -d --no-build --wait --wait-timeout 120
# Stop only the local API; exercise the actual production host script on the same data network.
compose stop api frontend
export APP_ROOT="$tmp/host" API_PROJECT="$project-api" DATA_NETWORK="${project}_default"
export API_ENV_FILE="$tmp/api.env" HEALTH_ATTEMPTS=15 HEALTH_DELAY=1
printf 'DB_HOST=postgres\nDB_PASSWORD=local-only-password\nREDIS_HOST=redis\nCORS_ORIGIN=https://app.example.test\n' > "$API_ENV_FILE"
bash "$here/../scripts/package-backend.sh" "$API_IMAGE" "$RELEASE_SHA" "$tmp/good.tar.gz"
bash "$here/../scripts/deploy-backend.sh" "$tmp/good.tar.gz" "$RELEASE_SHA"
next=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
if [[ $RELEASE_SHA == "$next" ]]; then next=dddddddddddddddddddddddddddddddddddddddd; fi
# shellcheck disable=SC2016 # Docker expands the build ARG, not this shell.
printf 'FROM %s\nARG RELEASE_SHA\nENV RELEASE_SHA=$RELEASE_SHA\nLABEL org.opencontainers.image.revision=$RELEASE_SHA\n' "$API_IMAGE" > "$tmp/Dockerfile"
docker build --load --build-arg "RELEASE_SHA=$next" -t "problem4-api:next-$$" "$tmp"
bash "$here/../scripts/package-backend.sh" "problem4-api:next-$$" "$next" "$tmp/next.tar.gz"
bash "$here/../scripts/deploy-backend.sh" "$tmp/next.tar.gz" "$next"
# Same-SHA success preserves the last distinct known-good release.
bash "$here/../scripts/deploy-backend.sh" "$tmp/next.tar.gz" "$next"
[[ $(cat "$APP_ROOT/previous/RELEASE") == "$RELEASE_SHA" ]]
bad=cccccccccccccccccccccccccccccccccccccccc
printf 'FROM %s\nENV RELEASE_SHA=%s\nLABEL org.opencontainers.image.revision=%s\nCMD ["node", "-e", "process.exit(1)"]\n' "$API_IMAGE" "$bad" "$bad" > "$tmp/Dockerfile"
docker build --load -t "problem4-api:bad-$$" "$tmp"
bash "$here/../scripts/package-backend.sh" "problem4-api:bad-$$" "$bad" "$tmp/bad.tar.gz"
if bash "$here/../scripts/deploy-backend.sh" "$tmp/bad.tar.gz" "$bad"; then echo 'Bad release unexpectedly succeeded' >&2; exit 1; fi
[[ $(cat "$APP_ROOT/current/RELEASE") == "$next" ]]
node "$here/http.mjs" "http://127.0.0.1:$API_PORT" "$next"
running=$(API_IMAGE=$(cat "$APP_ROOT/current/IMAGE") docker compose -p "$API_PROJECT" -f "$here/../deploy/compose.api.yaml" ps -q api)
[[ $(docker inspect --format '{{.Image}}' "$running") == "$(cat "$APP_ROOT/current/IMAGE")" ]]
[[ $(compose ps -q postgres) == "$pg" && $(compose ps -q redis) == "$redis" ]]
[[ $(compose exec -T postgres psql -U postgres -Atc 'SELECT value FROM release_probe') == survives ]]
# Host lock must fail before mutation when held by another process.
flock "$APP_ROOT/deploy.lock" sleep 3 &
locker=$!
sleep 0.2
if LOCK_TIMEOUT=0 bash "$here/../scripts/deploy-backend.sh" "$tmp/good.tar.gz" "$RELEASE_SHA"; then exit 1; fi
wait "$locker"
# Real graceful stop exits cleanly, rather than Docker's forced SIGKILL.
id=$(API_IMAGE=$(cat "$APP_ROOT/current/IMAGE") docker compose -p "$API_PROJECT" -f "$here/../deploy/compose.api.yaml" ps -q api)
docker stop --time 15 "$id"
[[ $(docker inspect --format '{{.State.ExitCode}}' "$id") == 0 ]]
# Separate durability drill: deliberate dependency recreation retains the named volume.
compose rm -sf postgres
compose up -d --no-deps --wait --wait-timeout 60 postgres
[[ $(compose exec -T postgres psql -U postgres -Atc 'SELECT value FROM release_probe') == survives ]]
echo 'PASS: real Docker stack, dependency outages, exact image deploy, failed-image rollback, persistence, lock and graceful shutdown'
