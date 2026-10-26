# Problem 1 — API and acceptance testing

[Solution](SOLUTION.md) · [Recorded results](evidence/results.md)

Run the commands below from `src/problem1` unless another directory is stated. Public API calls need no AWS IAM access. Authenticated calls need privately supplied demo credentials. Operator commands require authorized sandbox access and can write data, create paid tasks or send load.

## API reference

Base URL: **https://v7kn37xo96.execute-api.ap-southeast-1.amazonaws.com**

| Method/path | Access | Result |
|---|---|---|
| `GET /health/live` | Public | Process health |
| `GET /health/ready` | Public | Database readiness |
| `GET /v1/markets` | Public | Market, increments and limits |
| `GET /v1/markets/BTC-USDT/orderbook?depth=20` | Public | Aggregated levels; depth 1–100 |
| `GET /v1/markets/BTC-USDT/trades` | Public | Latest 50 trades |
| `GET /v1/balances` | Access token | Caller-owned available/reserved funds |
| `POST /v1/orders` | Access token | Durable submission; requires `Idempotency-Key`; returns `202` |
| `GET /v1/orders?cursor=...` | Access token | Owned history, 50 rows/page and `next_cursor` |
| `GET /v1/orders/{id}` | Access token | Owned state and up to 50 recent fills |
| `DELETE /v1/orders/{id}` | Access token | Durable cancellation request; returns `202` |

Errors: `400` invalid input, `401/403` authentication/access failure, `404` absent or other-account order, `409` conflicting key, `422` insufficient funds, `503` temporary dependency failure. Retry uncertain submissions with the same key and body.

## Live API walkthrough — PowerShell

The Cognito call needs no AWS IAM credentials. Do not print or commit the resulting token.

```powershell
$config = Get-Content ./evidence/public-config.json -Raw | ConvertFrom-Json
$base = $config.api_url
Invoke-RestMethod "$base/v1/markets"
Invoke-RestMethod "$base/v1/markets/BTC-USDT/orderbook?depth=20"

$credential = Get-Credential -Message 'Enter the supplied demo username and password'
$authBody = @{
  AuthFlow = 'USER_PASSWORD_AUTH'
  ClientId = $config.client_id
  AuthParameters = @{
    USERNAME = $credential.UserName
    PASSWORD = $credential.GetNetworkCredential().Password
  }
} | ConvertTo-Json -Depth 4
$auth = Invoke-RestMethod -Method Post `
  -Uri "https://cognito-idp.$($config.region).amazonaws.com/" `
  -ContentType 'application/x-amz-json-1.1' `
  -Headers @{'X-Amz-Target'='AWSCognitoIdentityProviderService.InitiateAuth'} `
  -Body $authBody
$authBody = $null
$headers = @{Authorization="Bearer $($auth.AuthenticationResult.AccessToken)"}
Invoke-RestMethod "$base/v1/balances" -Headers $headers

# Low-price demo buy: reserve 1 USDT without intentionally crossing fixture liquidity.
$headers['Idempotency-Key'] = [guid]::NewGuid().ToString()
$body = '{"market":"BTC-USDT","side":"BUY","price":"1.00","quantity":"1.00"}'
$order = Invoke-RestMethod -Method Post -Uri "$base/v1/orders" `
  -Headers $headers -ContentType 'application/json' -Body $body
$retry = Invoke-RestMethod -Method Post -Uri "$base/v1/orders" `
  -Headers $headers -ContentType 'application/json' -Body $body
if ($retry.id -ne $order.id) { throw 'Idempotency check failed' }
Invoke-RestMethod "$base/v1/orders/$($order.id)" -Headers $headers
Invoke-RestMethod -Method Delete -Uri "$base/v1/orders/$($order.id)" -Headers $headers

for ($i=0; $i -lt 20; $i++) {
  $state = Invoke-RestMethod "$base/v1/orders/$($order.id)" -Headers $headers
  if ($state.status -in @('CANCELLED','FILLED')) { break }
  Start-Sleep -Milliseconds 500
}
if ($state.status -notin @('CANCELLED','FILLED')) { throw 'Order did not reach a terminal state' }
$state
Invoke-RestMethod "$base/v1/balances" -Headers $headers
```

Expected: retry returns the same ID; cancellation eventually reaches a terminal state. Funds return for an unfilled cancellation; FILLED means execution won the race. Use the automated check below for matching and cross-account rejection with two demo accounts.

## Acceptance checks

| Check | Pass condition | Recorded evidence |
|---|---|---|
| API behaviour and authorization | Expected statuses; same retry ID; matching/cancellation complete; other-account access rejected | [functional.json](evidence/functional.json): 10 checks passed |
| Financial correctness | All local tests pass; no negative/unbalanced/unreconciled state | [correctness-tests.json](evidence/correctness-tests.json): 11 tests passed |
| 500 RPS / p99 <100 ms | Correct measured volume, aggregate and each exercised route p99 <100 ms; no dropped load | [raw run](evidence/load-1792905854-mixed.json) and [summary](evidence/results-summary.json) |
| Engine progress | Inspect sampled queue age during load; queue drains afterwards | [audit-latest.json](evidence/audit-latest.json) and raw-run queue samples |
| HA configuration | Two-AZ API/worker placement; private encrypted RDS Multi-AZ | [deployment.json](evidence/deployment.json) |

### Local correctness suite

Prerequisites: Node 24 and a **disposable** PostgreSQL 18 database `trading` on loopback port 55432 with password `local-test-only`. The suite truncates fixtures and injects a failing SQL trigger. Do not reuse a shared database. From `src/problem1/app`:

```powershell
$env:DB_HOST='127.0.0.1'; $env:DB_PORT='55432'
$env:DB_USER='postgres'; $env:DB_PASSWORD='local-test-only'
$env:DB_NAME='trading'; $env:DB_SSL='false'
npm.cmd ci --registry=https://registry.npmjs.org
npm.cmd test
```

Expected: 11 tests pass. They cover overlap, replay, overspending, matching/refunds, exact amounts, rollback/retry, cancellation, ownership and pagination. Local tests do not verify the gateway or AWS throughput.

### Live functional and load checks

Prerequisites: Python, AWS CLI/SSO, Terraform, authorized deployment-account access and demo credentials available to the operator. Helpers are pinned to the recorded sandbox/profile. Another account requires deliberate configuration changes.

```powershell
aws sso login --profile AWSAdministratorAccess-730335245469
python scripts/manage.py bootstrap             # Configure encrypted/versioned state backend
.\scripts\verify.ps1                          # 10 live checks, then financial audit
python scripts/manage.py admin seed-book       # Idempotent 400-order fixture
python scripts/manage.py load 500 180s mixed
python scripts/manage.py admin audit
python scripts/manage.py report
```

These operations write simulated data and run temporary paid tasks. The load profile uses 20 seconds of warm-up plus 180 measured seconds. It is 50% book reads, 20% balances, 10% history, 10% submissions and 10% recent trades.

Pass gates: aggregate and each exercised route p99 <100 ms; unexpected response rate <0.1%; zero dropped iterations; measured count within five requests of 90,000 at the timing boundary; no financial violations and a drained queue. The recorded run had zero unexpected responses. A fast 202 with growing backlog is not sustainable capacity. Queue samples are not execution-latency percentiles.

### Optional fault checks

`python scripts/manage.py recovery task` stops an API task; `python scripts/manage.py recovery database` forces database failover. Run only in an approved isolated test window, then check recovery, idempotent replay and financial state. These tests were not repeated in the current sandbox. Configuration evidence is not a fault-injection or restore result.

## Deployment and cleanup

For a new stack only, use `.\scripts\deploy.ps1 -Initial -ImageTag <new-immutable-tag>`. Review account/profile, cost and plan first. `-Initial` scales services to zero; do not use it on an existing live stack. ECR rejects reused tags.

For schema-changing releases, register and run migration with the intended new image before service rollout. The current wrapper can otherwise select the existing worker definition. Application rollback does not reverse schema changes.

To remove the stack, inspect `python scripts/manage.py terraform plan -destroy`, then run an approved `python scripts/manage.py terraform destroy`. A final RDS snapshot remains billable until deliberately removed. Remove retained RDS logs and the versioned state/source bucket only after stack deletion, including bucket versions/delete markers. Secrets use a seven-day recovery window. Never delete state first.
