const { ARTIFACT_BUCKET, ARCHIVE_KEY, RELEASE_SHA, DEPLOY_CODE, ARCHIVE_SHA256 } = process.env;
console.log(JSON.stringify({
  executionTimeout: ['900'],
  commands: [`set -eu
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
aws s3 cp 's3://${ARTIFACT_BUCKET}/${ARCHIVE_KEY}' "$tmp/release.tar.gz" --only-show-errors
echo '${DEPLOY_CODE}' | base64 -d > "$tmp/deploy.sh"
ARCHIVE_SHA256='${ARCHIVE_SHA256}' bash "$tmp/deploy.sh" "$tmp/release.tar.gz" '${RELEASE_SHA}'`],
}));
