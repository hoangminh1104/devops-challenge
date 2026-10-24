# Problem 4 — Ship It Twice

Problem 3 is the product: its actual shared `../problem3/api` runs in a non-root Node 24 image with lockfile-based `npm ci`. PostgreSQL and Redis support the API; a small static UI shows dependency health, release identity and database time. Local nginx proxies `/api`; production static files go to private S3/CloudFront and call a build-time HTTPS API URL.

## Run locally

From the repository root, with Docker Engine/Desktop and Compose v2+:

```bash
docker compose -p problem4 -f src/problem4/compose.yaml up --build -d --wait
curl http://localhost:8080/api/health
```

Open `http://localhost:8080`. API also listens on localhost:3000. Only frontend/API publish ports; PostgreSQL has a named data volume. `docker compose -p problem4 -f src/problem4/compose.yaml down` preserves it. `down -v` deliberately deletes local data. The local password is only an example; production uses an external root-owned secret file.

## Pipelines and recovery

Root workflows [backend](../../.github/workflows/problem4-backend.yml) and [frontend](../../.github/workflows/problem4-frontend.yml) independently validate PRs without cloud credentials. Backend filters include the shared Problem 3 source, Docker context and integration fixtures. Main pushes transfer tested archives through pinned GitHub artifact actions to separate protected deployment jobs. Only deploy jobs receive OIDC permission. Actions are revision-pinned; job timeouts, main-only guards and per-application concurrency apply to normal releases and manual recovery. Required environment reviewers and main-only environment branch rules must be configured in GitHub separately.

Backend CI builds and tests the actual image with real PostgreSQL/Redis before `docker save`. The single gzip archive contains image bytes, full commit SHA, immutable Docker image ID, production API Compose file and member checksums. S3 conditional creation rejects different bytes for an existing SHA key. SSM downloads and checks the runner-observed archive SHA-256, loads that image and runs only `compose up --no-deps --pull never api`. It never recreates dependencies. Health must contain the exact release SHA and healthy PostgreSQL/Redis JSON fields. Host `flock` serializes updates. Failure restores the previous API image, checks recovery and still returns failure. Same-SHA retries preserve the last distinct known-good release.

Frontend keeps the restrictive two-file archive: `index.html` and one SHA-256-named JS asset. SHA archive keys use conditional creation with exact readback comparison on retries, just like backend. `API_BASE_URL` is compiled into the JS, so configuration changes alter its hash. Assets publish before HTML, old assets remain, then CloudFront invalidation and HTTPS full-HTML/exact-asset smoke checks run. API requests time out after 10 seconds so users can retry. Manual recovery republishes archived bytes; it never rebuilds. Failed frontend publication requires explicit archived recovery.

For either workflow, dispatch from **main** with a retained full lowercase `release_sha`. Operator equivalents:

```bash
bash src/problem4/scripts/release-backend.sh recover FULL_40_CHARACTER_SHA
bash src/problem4/scripts/release-frontend.sh recover FULL_40_CHARACTER_SHA
```

See [deployment setup and artifact contract](deploy/README.md) for EC2 bootstrap, private-host image loading, IAM, variables and recovery details. Infrastructure provisioning is separate.

## Verification and current evidence

**Live application: https://d34e7lkj3dq7h3.cloudfront.net.** See [live resources and UI testing walkthrough](deploy/LIVE.md) for exact names, evidence, GitHub configuration and cleanup. CloudFront routes `/api/*` to the private EC2 through a restricted ALB, so the SPA uses the same HTTPS origin without a custom domain.

From `src/problem4`, Linux Bash and Node 24:

```bash
npm ci --prefix frontend
npm test --prefix frontend
RELEASE_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb API_BASE_URL=https://api.example.com npm run build --prefix frontend
bash tests/releases.sh
bash tests/host-contract.sh
bash tests/docker.sh
shellcheck scripts/*.sh tests/*.sh tests/doubles/* tests/host-double/*
actionlint ../../.github/workflows/problem4-backend.yml ../../.github/workflows/problem4-frontend.yml
bash tests/static.sh
```

Verified locally on 2026-10-24: frontend installation, four UI/build tests (including stalled-fetch abort/retry) and production-configured build; actual release scripts against mocked AWS/CDN; host-script control flow against a Docker double; real tar/checksum/filesystem/flock behavior; ShellCheck 0.10.0, actionlint 1.7.7, Bash/JS syntax, Compose config and IAM JSON parsing. Follow-up `tests/static.sh`, `tests/releases.sh`, `tests/host-contract.sh` and frontend `npm test` all passed. Regression checks cover persistent exported host settings during releases/rollback, frontend byte-identical retry versus changed-byte rejection before site writes, full-HTML mismatch with matching release meta, existing frontend artifact IAM read/list grants, and raw secret-file declarations in both production Compose files. Raw-format Docker runtime behavior was not exercised. The host double also covers success, failed candidate, failed active-SHA retry, startup failure, stale identity, failed dependency health, first-release failure, integrity/allowlist rejection and lock contention. These are supplemental orchestration checks, not container evidence.

Docker Desktop remains blocked by organization sign-in locally. **The real Docker suite subsequently passed on private EC2**, command `457c36c0-6c9d-41ce-8df7-14f04727f75b`, including HTTP directly/through nginx, non-root execution, CORS, dependency outages, exact image deployment, failed-image recovery, unchanged dependency containers, persisted SQL state, host lock and graceful shutdown. GitHub CI requires that same suite before packaging.

AWS account `516418317632`, `ap-southeast-1`: private EC2 has Docker/Compose, PostgreSQL/Redis and the tested API. Bootstrap deployment command `638d7165-1001-4c1e-802e-136e754637af` succeeded. HTTPS checks through CloudFront returned frontend 200, healthy dependencies and real database time. Initial test release uses `aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa`, not a source commit. A dedicated NAT instance provides egress; ALB reaches API port 3000 only from its security group. Details and limitations are in LIVE.md.

No commits, pushes, GitHub workflow runs or OIDC exchanges have occurred. GitHub environment branch rules and variables are configured, but the current plan rejects required-reviewer gates; main deployment is automatic after successful CI. CloudFront deployment and public HTTP checks passed; manual browser verification remains available at the live URL.

## Assumptions and omissions

Single Linux amd64 EC2, preloaded dependency images, external runtime secrets, and no schema migrations. API recreation briefly interrupts requests; no zero-downtime/HA claim. GitHub concurrency is not FIFO and can replace pending jobs; host locking protects overlapping SSM executions. Runner timeout does not cancel an already-running SSM command: inspect its ID before retrying. Process kill/reboot during update may need manual archived recovery. Retain known-good local images and S3 archives; cleanup, database backups/restores, secret rotation, monitoring, Terraform, autoscaling, signatures and automated frontend rollback are outside this small submission. App rollback does not roll back data.
