# DevOps Challenge — Solutions

Independent submission by [hoangminh1104](https://github.com/hoangminh1104), based on the [original challenge](https://github.com/99techteam/devops-challenge). This repository was created independently, not as a GitHub fork.

## Review guide

Start with each problem's report. Follow its testing and evidence links to verify the implementation and its limits.

| Problem | Start here | What to check |
|---|---|---|
| **1 — Cloud architecture** | [Solution](src/problem1/SOLUTION.md) · [Testing](src/problem1/TESTING.md) | AWS architecture, service alternatives, scaling, APIs and the recorded 500-RPS benchmark |
| **2 — Disk troubleshooting** | [Solution](src/problem2/SOLUTION.md) | Investigation order, possible causes, safe recovery and verification |
| **3 — Debugging** | [Investigation report](src/problem3/report.md) · [Local setup](src/problem3/README.md) | Root causes, fixes, before/after observations and dependency-failure checks |
| **4 — CI/CD** | [Solution](src/problem4/SOLUTION.md) · [Workflows](.github/workflows/) | Independent backend/frontend releases, validation, retained artifacts, deployment and rollback |
| **5 — Security** | [Solution](src/problem5/SOLUTION.md) · [Testing](src/problem5/TESTING.md) | Marked architecture changes, threat coverage, accepted risks and the independent Docker security lab |

## Demos and verification

- **Problem 1:** [public market API](https://v7kn37xo96.execute-api.ap-southeast-1.amazonaws.com/v1/markets). The recorded regional, 10%-submission workload achieved 500 RPS with 29 ms aggregate p99 and 54 ms submission p99. Order acceptance is durable; matching is asynchronous. [Evidence](src/problem1/evidence/results.md).
- **Problem 4:** [deployed frontend](https://d1v3sagma6ldre.cloudfront.net). Deployment and recovery run links are in the solution report.
- **Problem 5:** local Docker lab, separate from Problem 1. Run its testing guide to reproduce the 12 security cases; no AWS security deployment is claimed.

Authenticated API demo credentials are supplied privately. Each report states its assumptions, verification scope and deliberate omissions. Live endpoints may be unavailable after sandbox cleanup; recorded evidence remains in the repository.
