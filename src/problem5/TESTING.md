# Problem 5 — security acceptance testing

[Solution](SOLUTION.md) · [Security results](evidence/security-results.json) · [Runtime inspection](evidence/runtime-controls.json)

## Start and verify

Requirements: Node 24, Docker Compose v2 and PowerShell. Run from `src/problem5`:

```powershell
.\scripts\run.ps1
```

The script generates/preserves P5-only fixture credentials, builds and starts two API replicas, a cancellation worker and PostgreSQL, inspects runtime restrictions, then runs the tests.

**The suite resets its dedicated `p5_security` fixture database. Do not run it against retained data.** Another copy using the same Compose project name on the same Docker daemon is not an independent lab. Use a separate context/project and adapt the scripts/ports before parallel testing.

Expected report: `total: 12`, `passed: 12`, `failed: 0`, `all_checks_passed: true`. Financial reconciliation counts `negative`, `unbalanced` and `unreconciled` must all be zero. Reports are written to `evidence/` without passwords, tokens or private keys.

## What the tests establish

| Acceptance check | Expected behaviour |
|---|---|
| Token validation | Missing, malformed, unsigned, expired, wrong-algorithm, wrong-issuer/audience and wrong-key tokens are rejected |
| Scope restrictions | Read-only tokens can read permitted data but cannot submit/cancel orders |
| Ownership | Alice cannot read/cancel Bob's order or replace her identity through a header/body field |
| Database permissions | API credentials cannot access base tables, perform DDL, rewrite the journal or assume owner/admin roles |
| Role separation | API/worker cannot call each other's routines; migration authority remains separate |
| Concurrent replay | Same account/key across replicas creates one order, one reservation and one quota charge; conflicting amount returns 409 |
| Overspending | Concurrent unaffordable requests cannot both succeed; rejected work leaves no partial reservation |
| Shared quota | Switching replicas does not multiply an account's accepted-new-order allowance |
| Atomic admission | Concurrent work stops at configured outstanding capacity; rejections reserve nothing |
| Cancellation | Cancellation remains available during closure; the worker releases funds once and reopens capacity |
| Input validation | Invalid amounts and SQL-shaped input fail; direct routine calls cannot bypass amount validation |
| Function configuration | Security-definer routines have the intended non-login owner, pinned path and no PUBLIC execution grant |

The runtime inspector separately checks non-root API/worker users, read-only roots, dropped capabilities, no-new-privileges, read-only narrow secret mounts, loopback API bindings and no published database port. The backend network must be internal. Application-module and package/lockfile hashes must match the inspected runtime.

## Cached-image reruns

If the compatible runtime image is already built:

```powershell
.\scripts\run.ps1 -SkipBuild
```

This uses `--no-build --pull never` and still runs runtime inspection and the tests. Hash comparison is not base-image attestation or a check of installed SQL definitions. Rebuild for Dockerfile/base/dependency changes. Bootstrap SQL runs only on first database initialization; reset disposable P5 data before testing changed bootstrap SQL.

## Read-only checks

```powershell
Invoke-RestMethod http://127.0.0.1:18085/health
Invoke-RestMethod http://127.0.0.1:18086/health
docker compose -p dom7hc-practice-p5 -f compose.yml ps
docker compose -p dom7hc-practice-p5 -f compose.yml logs --tail 60 db api-a api-b worker
```

Health checks establish database connectivity for the API, not every security property or worker progress. The trusted test runner signs tokens in memory; runtime APIs never receive the private signing key.

## Cleanup

```powershell
.\scripts\cleanup.ps1             # Stop only P5; retain its database volume
.\scripts\cleanup.ps1 -ResetData  # Also delete only P5's fixture volume
```

Keep local passwords aligned with a retained volume. Deleting password files while keeping the database creates a credential mismatch. No global Docker prune or AWS cleanup is needed.

## Evidence boundary

The recorded run passed all 12 cases. The copied submission passed again in a temporary project with fresh data and alternate loopback ports; that verification project was removed afterwards. See [evidence/README.md](evidence/README.md).

These checks demonstrate the named lab controls. They do not establish a penetration-test result, administrator-proof immutability, general DDoS protection, AWS hardening or production performance. The proposed architecture, accepted risks and missing facts remain in [SOLUTION.md](SOLUTION.md).
