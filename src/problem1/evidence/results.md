# Problem 1 — validation results

Recorded on **25 October 2026**, AWS Singapore. These are dated deployment/test results, not a guarantee of current endpoint availability.

## Performance acceptance

| Check | Result |
|---|---:|
| Offered rate / measured duration | 500 RPS / 180 seconds |
| Completed measured requests | 90,001; about 500.01 RPS |
| Aggregate p99 | **29 ms** |
| Submission p99 | **54 ms** |
| Book / balances / history / trade-read p99 | 27 / 36 / 21 / 13 ms |
| Unexpected responses / dropped iterations | **0 / 0** |
| Highest sampled pending count / oldest-command age | 8 / about 190 ms |
| Post-run pending commands | **0** |

Sources: [raw run](load-1792905854-mixed.json), [summary](results-summary.json), [post-run audit](audit-latest.json).

**Workload:** 50% book reads, 20% balances, 10% history, 10% placements, 10% recent trades; eight funded accounts; one synthetic BTC-USDT market; 400 non-crossing fixture orders across 20 price levels per side. See [book-fixture.json](book-fixture.json).

**Measurement:** temporary Singapore generator, 2 vCPUs/8 GB, 500 pre-initialized clients, 20-second warm-up followed by the measured window. One continuous constant-arrival scenario. Elapsed request timing includes the public HTTPS/gateway path and committed acceptance. Request count allows five requests of timing-boundary tolerance; zero-dropped-load and latency checks remain strict.

**Limits:** 202 means durable reservation/order acceptance, not completed execution. Queue observations are periodic samples, not execution p99 or absolute maxima. This is not an arbitrary-mix benchmark, all-day soak, global internet latency guarantee or AZ-loss capacity test. A previous environment's 80%-write stress test failed; those historical results are not claimed as a repeat test of this deployment.

## Functional and correctness acceptance

- **11 database-backed tests passed** before publishing: concurrent replay, overspending, maker-price settlement/refunds, priority/partial fills, cancellation, self-trade prevention, rollback/retry, simultaneous workers, exact fractions, ownership/validation and pagination. [Test receipt](correctness-tests.json), [build receipt](build-latest.json).
- **10 live checks passed:** public HTTPS, missing-token rejection, unsigned/header-substitution rejection, valid access token, ID-token rejection through required scope, durable acceptance/replay, matching, ownership and cancellation. [Functional receipt](functional.json).
- **5,001 trades reconciled:** no negative balances, unbalanced journal events, unreconciled balances or pending commands. [Audit](audit-latest.json).

## Infrastructure acceptance

- Two healthy API tasks and two healthy workers span two AZs.
- PostgreSQL is private, encrypted and Multi-AZ, with seven-day backups.
- Terraform formatting/validation passed; the recorded final plan had no changes.

Sources: [deployment.json](deployment.json), [infrastructure-check.json](infrastructure-check.json). Task/database failover was not rerun in this deployment; no new fault-injection or restore RTO/RPO result is claimed.

Reproduce with the [acceptance test guide](../SOLUTION.md#acceptance-test-guide). Live tests write simulated data and create short-lived paid tasks. Credentials are supplied privately; no tokens, passwords, private keys or Terraform state are included here.
