#!/usr/bin/env bash
set -Eeuo pipefail
mode=${1:?release or recover}
sha=${2:?SHA required}
[[ $mode == release || $mode == recover ]] || exit 2
[[ $sha =~ ^[a-f0-9]{40}$ ]] || exit 2
: "${ARTIFACT_BUCKET:?}" "${SITE_BUCKET:?}" "${DISTRIBUTION_ID:?}" "${SITE_URL:?}"
[[ $SITE_URL =~ ^https://[a-zA-Z0-9.-]+$ ]] || exit 2
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
archive="$tmp/release.tar.gz"
key="s3://$ARTIFACT_BUCKET/frontend/$sha.tar.gz"
if [[ $mode == release ]]; then
  cp "${3:?archive required}" "$archive"
else
  aws s3 cp "$key" "$archive" --only-show-errors
fi
# No absolute paths, traversal, symlinks, or arbitrary filenames in recovery archives.
tar -tzf "$archive" > "$tmp/names"
while IFS= read -r name; do
  [[ $name == index.html || $name =~ ^assets/app-[a-f0-9]{64}\.js$ ]] || exit 2
done < "$tmp/names"
[[ $(grep -cx index.html "$tmp/names") == 1 && $(wc -l < "$tmp/names") == 2 ]] || exit 2
if tar -tvzf "$archive" | grep -qv '^-'; then exit 2; fi
mkdir "$tmp/site"
tar -xzf "$archive" -C "$tmp/site" --no-same-owner --no-same-permissions
grep -qF "<meta name=\"release\" content=\"$sha\">" "$tmp/site/index.html"
asset=$(grep '^assets/' "$tmp/names")
digest=$(sha256sum "$tmp/site/$asset")
[[ $asset == "assets/app-${digest%% *}.js" ]] || exit 2
grep -qF "src=\"/$asset\"" "$tmp/site/index.html"
if [[ $mode == release ]]; then
  # Match backend publication: a SHA can only ever identify these exact bytes.
  if ! aws s3api put-object --bucket "$ARTIFACT_BUCKET" --key "frontend/$sha.tar.gz" --body "$archive" \
    --if-none-match '*' --checksum-algorithm SHA256 > "$tmp/put.json"; then
    aws s3 cp "$key" "$tmp/existing.tar.gz" --only-show-errors
    cmp "$archive" "$tmp/existing.tar.gz"
  fi
fi
# Deliberately no sync --delete: older HTML must still be able to load its assets.
aws s3 cp "$tmp/site/assets/" "s3://$SITE_BUCKET/assets/" --recursive \
  --cache-control 'public,max-age=31536000,immutable' --content-type application/javascript --only-show-errors
aws s3 cp "$tmp/site/index.html" "s3://$SITE_BUCKET/index.html" \
  --cache-control 'no-cache,max-age=0,must-revalidate' --content-type text/html --only-show-errors
id=$(aws cloudfront create-invalidation --distribution-id "$DISTRIBUTION_ID" --paths '/*' \
  --query Invalidation.Id --output text)
aws cloudfront wait invalidation-completed --distribution-id "$DISTRIBUTION_ID" --id "$id"
curl --fail --silent --show-error --retry 5 --retry-all-errors --max-time 15 \
  "$SITE_URL/index.html" > "$tmp/live.html"
cmp "$tmp/site/index.html" "$tmp/live.html"
curl --fail --silent --show-error --retry 5 --retry-all-errors --max-time 15 \
  "$SITE_URL/$asset" > "$tmp/live.js"
cmp "$tmp/site/$asset" "$tmp/live.js"
echo "Published and smoke-tested $sha"
