#!/usr/bin/env bash
set -Eeuo pipefail
mode=${1:?release or recover}
sha=${2:?SHA required}
[[ $mode == release || $mode == recover ]] || exit 2
[[ $sha =~ ^[a-f0-9]{40}$ ]] || exit 2
: "${ARTIFACT_BUCKET:?}" "${INSTANCE_ID:?}"
[[ $ARTIFACT_BUCKET =~ ^[a-z0-9][a-z0-9.-]+$ && $INSTANCE_ID =~ ^i-[a-f0-9]+$ ]] || exit 2
here=$(cd -- "$(dirname -- "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
key="backend/$sha.tar.gz"
if [[ $mode == release ]]; then
  archive=${3:?archive required}
  # Conditional creation prevents a retry/rebuild from replacing a SHA's bytes.
  if ! aws s3api put-object --bucket "$ARTIFACT_BUCKET" --key "$key" --body "$archive" \
    --if-none-match '*' --checksum-algorithm SHA256 > "$tmp/put.json"; then
    aws s3 cp "s3://$ARTIFACT_BUCKET/$key" "$tmp/existing.tar.gz" --only-show-errors
    cmp "$archive" "$tmp/existing.tar.gz"
  fi
else
  archive="$tmp/recovered.tar.gz"
  aws s3 cp "s3://$ARTIFACT_BUCKET/$key" "$archive" --only-show-errors
fi
export ARCHIVE_SHA256
ARCHIVE_SHA256=$(sha256sum "$archive"); ARCHIVE_SHA256=${ARCHIVE_SHA256%% *}
# Send code from this trusted checkout, never shell-interpolate user input.
export DEPLOY_CODE
DEPLOY_CODE=$(base64 -w0 "$here/deploy-backend.sh")
export RELEASE_SHA=$sha ARCHIVE_KEY=$key
node "$here/ssm-parameters.mjs" > "$tmp/parameters.json"
id=$(aws ssm send-command --document-name AWS-RunShellScript --instance-ids "$INSTANCE_ID" \
  --parameters "file://$tmp/parameters.json" --timeout-seconds 120 \
  --query Command.CommandId --output text)
echo "SSM command: $id"
for ((attempt=0; attempt<200; attempt++)); do
  if aws ssm get-command-invocation --command-id "$id" --instance-id "$INSTANCE_ID" \
    --output json > "$tmp/result.json" 2> "$tmp/error"; then
    status=$(node -e 'const fs=require("fs"); console.log(JSON.parse(fs.readFileSync(process.argv[1])).Status)' "$tmp/result.json")
    case "$status" in
      Success) cat "$tmp/result.json"; exit 0 ;;
      Pending|InProgress|Delayed) ;;
      *) cat "$tmp/result.json"; exit 1 ;;
    esac
  elif ! grep -q InvocationDoesNotExist "$tmp/error"; then
    cat "$tmp/error" >&2; exit 1
  fi
  sleep "${SSM_POLL_DELAY:-5}"
done
echo "SSM polling timed out; command $id may still be running. Check it before retrying." >&2
exit 1
