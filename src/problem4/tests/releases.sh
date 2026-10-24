#!/usr/bin/env bash
set -Eeuo pipefail
here=$(cd -- "$(dirname -- "$0")" && pwd)
scripts="$here/../scripts"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin"
cp "$here"/doubles/* "$tmp/bin/"
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$PATH"
export OLD_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa NEW_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
export SSM_POLL_DELAY=0 MOCK_STATE="$tmp/state"
mkdir -p "$MOCK_STATE"
must_fail() { if "$@"; then echo "Expected failure: $*" >&2; exit 1; fi; }
export ARTIFACT_BUCKET=archive-test INSTANCE_ID=i-123abc
echo 'opaque tested image archive' > "$tmp/api.tar.gz"
bash "$scripts/release-backend.sh" release "$NEW_SHA" "$tmp/api.tar.gz"
[[ $(cat "$MOCK_STATE/polls") == 3 ]]
node -e 'const fs=require("fs"); const p=JSON.parse(fs.readFileSync(process.argv[1])); if(p.executionTimeout[0]!=="900" || !p.commands[0].includes(process.argv[2]) || !/ARCHIVE_SHA256=\x27[a-f0-9]{64}\x27/.test(p.commands[0])) process.exit(1)' "$MOCK_STATE/parameters.json" "$NEW_SHA"
rm "$MOCK_STATE/polls"
# Byte-identical retry succeeds; changed bytes cannot replace the SHA key.
bash "$scripts/release-backend.sh" release "$NEW_SHA" "$tmp/api.tar.gz"
echo changed > "$tmp/changed.tar.gz"
must_fail bash "$scripts/release-backend.sh" release "$NEW_SHA" "$tmp/changed.tar.gz"
rm "$MOCK_STATE/polls"
SSM_STATUS=Failed must_fail bash "$scripts/release-backend.sh" recover "$NEW_SHA"
must_fail bash "$scripts/release-backend.sh" recover "$OLD_SHA"
must_fail bash "$scripts/release-backend.sh" recover 'bad;command'
rm "$MOCK_STATE/polls"
bash "$scripts/release-backend.sh" recover "$NEW_SHA"
# Execute the actual generated shell payload with a recorder for the host deploy helper.
export RELEASE_SHA="$NEW_SHA" ARCHIVE_KEY="backend/$NEW_SHA.tar.gz"
export ARCHIVE_SHA256
ARCHIVE_SHA256=$(sha256sum "$tmp/api.tar.gz"); ARCHIVE_SHA256=${ARCHIVE_SHA256%% *}
export DEPLOY_CODE
# shellcheck disable=SC2016 # Arguments are expanded on the simulated remote host.
DEPLOY_CODE=$(printf 'test "$2" = "%s"; test "$ARCHIVE_SHA256" = "%s"; test -s "$1"\n' "$NEW_SHA" "$ARCHIVE_SHA256" | base64 -w0)
node "$scripts/ssm-parameters.mjs" > "$tmp/payload.json"
node -e 'const fs=require("fs"); fs.writeFileSync(process.argv[2],JSON.parse(fs.readFileSync(process.argv[1])).commands[0])' "$tmp/payload.json" "$tmp/remote.sh"
bash "$tmp/remote.sh"
echo 'PASS: S3 immutable SHA bytes, SSM payload/digest, eventual consistency, terminal failure, missing recovery and identifier rejection'

export SITE_BUCKET=site-test DISTRIBUTION_ID=TEST SITE_URL=https://example.test
mkdir "$tmp/frontend"
(cd "$tmp/frontend"; RELEASE_SHA="$NEW_SHA" node "$here/../frontend/build.mjs")
(cd "$tmp/frontend/dist"; tar -czf "$tmp/spa.tar.gz" index.html assets/*.js)
mkdir -p "$MOCK_STATE/site/assets"
echo old > "$MOCK_STATE/site/assets/old.js"
: > "$MOCK_STATE/aws.log"
bash "$scripts/release-frontend.sh" release "$NEW_SHA" "$tmp/spa.tar.gz"
[[ -f $MOCK_STATE/site/assets/old.js ]]
assets_line=$(grep -n 's3://site-test/assets/' "$MOCK_STATE/aws.log" | cut -d: -f1)
html_line=$(grep -n 's3://site-test/index.html' "$MOCK_STATE/aws.log" | cut -d: -f1)
[[ $assets_line -lt $html_line ]]
# Identical retry succeeds; a valid archive with changed HTML cannot replace a SHA.
bash "$scripts/release-frontend.sh" release "$NEW_SHA" "$tmp/spa.tar.gz"
echo '<!-- changed build -->' >> "$tmp/frontend/dist/index.html"
(cd "$tmp/frontend/dist"; tar -czf "$tmp/changed-spa.tar.gz" index.html assets/*.js)
: > "$MOCK_STATE/aws.log"
must_fail bash "$scripts/release-frontend.sh" release "$NEW_SHA" "$tmp/changed-spa.tar.gz"
cmp "$tmp/spa.tar.gz" "$MOCK_STATE/archive/frontend/$NEW_SHA.tar.gz"
if grep -q 's3://site-test/' "$MOCK_STATE/aws.log"; then exit 1; fi
# A matching release meta is insufficient: the entire served HTML must match.
CORRUPT_HTML=yes must_fail bash "$scripts/release-frontend.sh" recover "$NEW_SHA"
echo broken > "$MOCK_STATE/site/index.html"
bash "$scripts/release-frontend.sh" recover "$NEW_SHA"
tar -xOf "$tmp/spa.tar.gz" index.html > "$tmp/expected.html"
cmp "$tmp/expected.html" "$MOCK_STATE/site/index.html"
must_fail bash "$scripts/release-frontend.sh" recover "$OLD_SHA"
must_fail bash "$scripts/release-frontend.sh" recover '../../bad'
ln -s /etc/passwd "$tmp/frontend/dist/link"
(cd "$tmp/frontend/dist"; tar -czf "$tmp/link.tar.gz" index.html link)
must_fail bash "$scripts/release-frontend.sh" release "$NEW_SHA" "$tmp/link.tar.gz"
: > "$MOCK_STATE/aws.log"
export FAIL_ASSETS=yes
must_fail bash "$scripts/release-frontend.sh" release "$NEW_SHA" "$tmp/spa.tar.gz"
if grep -q 's3://site-test/index.html' "$MOCK_STATE/aws.log"; then exit 1; fi
unset FAIL_ASSETS
echo 'PASS: frontend immutable SHA bytes/retries, exact HTML smoke, publication ordering, retention, archived recovery, unsafe archives, missing archive and upload failure'
