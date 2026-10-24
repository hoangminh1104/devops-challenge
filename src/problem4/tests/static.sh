#!/usr/bin/env bash
set -Eeuo pipefail
here=$(cd -- "$(dirname -- "$0")" && pwd)
cd "$here/.."
for file in scripts/*.sh tests/*.sh tests/doubles/* tests/host-double/*; do bash -n "$file"; done
node --check ../problem3/api/src/index.js
node --check tests/http.mjs
node --check scripts/ssm-parameters.mjs
node --input-type=module -e 'import fs from "node:fs"; for (const f of fs.readdirSync("deploy").filter(f => f.endsWith(".json"))) JSON.parse(fs.readFileSync("deploy/" + f));'
# Guard the literal-secret contract for both producers/consumers without Docker.
for file in deploy/compose.api.yaml deploy/compose.dependencies.yaml; do
  # shellcheck disable=SC2016 # Match the literal Compose expression.
  grep -qF 'path: ${API_ENV_FILE:-/etc/ship-api.env}' "$file"
  grep -q '^[[:space:]]*format: raw$' "$file"
done
node --input-type=module -e '
  import fs from "node:fs";
  import assert from "node:assert/strict";
  const {Statement: statements} = JSON.parse(fs.readFileSync("deploy/permissions-frontend.json"));
  for (const action of ["s3:PutObject", "s3:GetObject"]) {
    assert(statements.some(s => [].concat(s.Action).includes(action) && s.Resource === "arn:aws:s3:::ARTIFACT_BUCKET/frontend/*"));
  }
  assert(statements.some(s => s.Action === "s3:ListBucket" && s.Resource === "arn:aws:s3:::ARTIFACT_BUCKET" && s.Condition.StringLike["s3:prefix"] === "frontend/*"));
'
shellcheck scripts/*.sh tests/*.sh tests/doubles/* tests/host-double/*
actionlint ../../.github/workflows/problem4-backend.yml ../../.github/workflows/problem4-frontend.yml
echo 'PASS: Bash/JS syntax, IAM JSON, ShellCheck and actionlint'
