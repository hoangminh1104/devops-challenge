---
title: Problem 4 Docker revision using Problem 3
status: done
baseline_commit: b50ef2994eda5b84dad54428793701bbf1445025
---

## Approved revised intent

User explicitly requests completion of Problem 4, treating Problem 3 as the web product. This supersedes prior restrictions against Docker and reusing Problem 3. Existing uncommitted Problem 4 files are the approved starting implementation. Preserve unrelated work. Implement locally first; no commits or pushes. User has authorized private EC2 setup and continuing Docker deployment there.

## Implementation contract

- Backend source is `src/problem3/api`, not a copy. Minimal compatible improvements: env credentials, lockfile, graceful shutdown, release SHA in health responses. Preserve Problem 3 defaults/routes.
- Problem 4 owns a Node24 non-root Dockerfile, local Compose stack (API, PostgreSQL, Redis, static frontend) and production Compose configuration. PostgreSQL persists; no dependency ports published. Local frontend can call API through a reverse proxy; deployed S3 SPA takes API URL at build time. Explain production HTTPS/CORS requirements honestly.
- Independent root GitHub Actions workflows: PR tests with no cloud credentials; main-only OIDC production deployment, pinned actions, protected environments, serialization and timeouts. Backend path filters include shared Problem 3 source. Test actual image with dependencies before packaging `docker save` image archive, then deploy exact bytes using S3/SSM. Frontend retains ordered assets-before-HTML S3/CDN publication and archived recovery.
- Backend deployment uses host lock, loads image, updates only API, verifies JSON dependency health and exact SHA, restores previous image on failure and returns nonzero. Same-SHA retries retain recovery state. Dependencies are bootstrapped explicitly, never reset/recreated by app release. No data rollback or migrations.
- Local commands must exercise real Docker HTTP behavior and failed-image recovery. Update IAM examples, scripts, README/report and meaningful tests. Retire superseded sample-backend/systemd files only after reference checks.
- Existing private EC2: account 516418317632, region ap-southeast-1, profile AWSAdministratorAccess-516418317632, instance i-06a3a1ca8845a1087, no public IP/internet route. Docker absent. Private S3/SSM endpoints exist. Any live evidence must state exactly what passed; no claim pipeline/OIDC/CDN ran unless actually exercised.

## Acceptance

- Given clean checkout and Docker, when documented local Compose command runs, then shared API and static frontend work with real PostgreSQL/Redis.
- Given built API image, when CI integration checks run, then endpoints and dependency readiness are tested before immutable image archive publication.
- Given failed candidate image, when deployment test runs, then previous API image is restored, database persists, and deployment returns failure.
- Given protected main release or manual recovery, when workflow executes, then only deploy job has OIDC and it deploys retained tested artifact, never rebuilds remotely.
- Given evaluator reads SOLUTION.md, then architecture, prerequisites, variables, local tests, recovery, assumptions, deliberate omissions and actual live status are explicit.

## Execution

- [x] Shared API and Docker/local Compose (implementation/config checks complete; runtime acceptance blocked below)
- [x] Backend Docker release scripts and root workflows (orchestration/static checks verified)
- [x] Static frontend integration and existing S3 pipeline
- [x] Real Docker integration/recovery test implementation and static checks; execution blocked as documented below
- [x] SOLUTION.md and deployment prerequisites

## Verification (2026-10-24)

- Node 24.14.0 frontend `npm ci`, four UI/build tests and production API URL build passed.
- `bash tests/releases.sh` passed mocked AWS publication/recovery/SSM payload checks; `bash tests/host-contract.sh` passed actual host script control flow with Docker double and real checksum/tar/flock.
- ShellCheck 0.10.0, actionlint 1.7.7, Bash/JS syntax, IAM JSON, all three Compose config checks and tracked whitespace checks passed.
- Real native Docker Compose build and WSL `bash tests/docker.sh` were attempted. Both are blocked by enforced Docker Desktop organization sign-in (`boschworldwide`); even image listing is denied. No real Docker image/build/recovery/persistence success is claimed. Runtime acceptance remains unverified pending authorized sign-in and rerun.
- Separate AWS bootstrap installed Docker on the private EC2 through Amazon Linux S3 repositories and verified engine startup via SSM. Docker Hub is unreachable without internet egress; no application deployment occurred. No commits, pushes or GitHub workflow runs.
- Deployment/artifact contract and exact repeatable commands are in [setup](../deploy/README.md) and [SOLUTION](../SOLUTION.md). API production Compose ships in every release; dependency Compose is a separate bootstrap prerequisite.

## Review and suggested review order

### Live follow-up

Real Docker suite now PASSED on private EC2, SSM command `457c36c0-6c9d-41ce-8df7-14f04727f75b`. Persistent API/dependencies deployed; CloudFront frontend and API public HTTPS checks passed. GitHub environments/variables/OIDC roles configured; required-reviewer rules rejected by current GitHub plan. No commits/pushes/workflow execution yet. Earlier blocker statements above are historical; current evidence is [LIVE.md](../deploy/LIVE.md).

Independent correctness and edge-case reviews completed. Fixed persistent host deployment configuration, immutable frontend publication, exact HTML smoke comparison, bounded UI requests and raw secret env-file handling. All static/orchestration/frontend checks passed after fixes.

1. [SOLUTION](../SOLUTION.md): architecture, assumptions and verification limits.
2. [Backend workflow](../../../../.github/workflows/problem4-backend.yml): tested image and credential boundary.
3. [Host deployment](../scripts/deploy-backend.sh): integrity, lock and recovery.
4. [Docker integration](../tests/docker.sh): actual runtime acceptance suite still requiring execution.
5. [Setup](../deploy/README.md): secrets, private image delivery and production prerequisites.
