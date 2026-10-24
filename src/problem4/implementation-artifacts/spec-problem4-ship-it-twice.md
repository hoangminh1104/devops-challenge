---
title: 'Problem 4: Ship It Twice'
type: feature
created: '2026-10-22'
status: done
baseline_commit: b50ef2994eda5b84dad54428793701bbf1445025
review_loop_iteration: 0
context: []
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** The challenge requires implemented GitHub Actions pipelines for an HTTP API on EC2 and a static SPA on S3, with a short report explaining production readiness, assumptions, and omissions. The current problem directory contains only a solution placeholder and an empty nested workflow directory.

**Approach:** Deliver a small, self-contained example demonstrating tested, commit-addressed artifacts and independent deployments. Use GitHub OIDC, SSM-controlled EC2 deployment with health-based rollback, and ordered S3 publication behind CloudFront with archived-release recovery. Keep the implementation appropriate to a two-hour exercise.

## Boundaries & Constraints

**Always:** Put executable workflows in the repository-root `.github/workflows/`. Validate pull requests without AWS access. Restrict production deployment to `main`, use separate GitHub production environments and scoped AWS roles, pin action revisions, bound execution time, and serialize each application's production mutations without cancelling active deployments. Deploy the artifact tested by the build job. Identify releases by full commit SHA. Surface remote execution failures. Report actual verification separately from AWS behavior that has not been exercised.

**Ask First:** Commits, pushes, pipeline runs, actual AWS mutations or deployments, changes to other challenge solutions, or material expansion of the approved scope.

**Never:** Add Terraform, staging, an orchestrator, database migrations, monitoring infrastructure, or claims of zero downtime/high availability. Do not reuse Problem 3's database-dependent API. Do not store AWS access keys, SSH keys, or runtime secrets in the repository. The two independent pipelines are intentionally retained together as the approved challenge submission.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|---------------|----------------------------|----------------|
| PR validation | Untrusted pull request | Tests and builds execute without production credentials | Fail before publication if validation fails |
| Backend release | Valid artifact and existing healthy release | New release becomes current and passes health checks | Report success only after SSM execution completes |
| Backend unhealthy | New process fails health polling | Previous release is restored and restarted | Report deployment failure even if recovery succeeds |
| First deploy fails | No previous release exists | Failed new service is stopped; no success is reported | Preserve diagnostic output and return failure |
| Frontend publish | New build with hashed assets | Assets upload before HTML; old assets remain available | Stop on upload error; document recovery after publication failures |
| Manual recovery | Previously archived release SHA | Exact archived release is republished | Reject malformed identifiers and fail if archive is missing |
| Concurrent releases | Two runs target one application | Production mutations do not overlap | Explain GitHub concurrency queue limitations |

</frozen-after-approval>

## Code Map

Historical implementation below is superseded by the approved [Docker revision](spec-problem4-docker-revision.md). Its sample backend/systemd files and corresponding tests were read and retired; current implementation and evidence are in that revision and [SOLUTION](../SOLUTION.md).

- `src/problem4/SOLUTION.md` — required evaluator-facing report, currently a placeholder.
- `src/problem4/.github/workflows/.gitkeep` — existing scaffold; not a discoverable workflow location.
- `.github/workflows/` — root workflow location to create.
- `src/problem3/` — separate challenge implementation, outside this change.
- `.gitignore` — already excludes dependency directories and credentials.

## Tasks & Acceptance

**Execution:**
- [x] `src/problem4/backend/` — add a dependency-light Node.js HTTP API, health endpoint, release identity, and meaningful HTTP tests; provide reproducible installation metadata.
- [x] `src/problem4/frontend/` — add a minimal SPA and deterministic static build with hashed assets, plus checks that emitted HTML references existing assets.
- [x] `src/problem4/scripts/deploy-backend.sh` — implement release extraction, serialized host-side mutation, current-release switch, restart, bounded health polling, and previous-release recovery.
- [x] `src/problem4/scripts/` — add AWS deployment orchestration and frontend publication/recovery helpers; keep workflow shell blocks small and validate inputs.
- [x] `src/problem4/deploy/api.service` — define a non-root systemd service with external runtime configuration and the documented release layout.
- [x] `.github/workflows/problem4-backend.yml` — implement PR/main validation, artifact transfer, protected deployment, OIDC, SSM result polling, and recovery dispatch.
- [x] `.github/workflows/problem4-frontend.yml` — implement validation, artifact transfer, OIDC, ordered publication, CloudFront invalidation, smoke checks, and recovery dispatch.
- [x] `src/problem4/deploy/` — add parameterized trust/permission policy examples separating frontend, backend, and instance authority.
- [x] `src/problem4/tests/` — exercise backend deployment success and failed-health recovery with local command doubles, including first-deployment failure.
- [x] `src/problem4/SOLUTION.md` — replace placeholder with architecture, setup variables, infrastructure assumptions, release/recovery instructions, checks performed, and explicit omissions.

**Acceptance Criteria:**
- Given a clean checkout, when documented local validation runs, then both sample applications pass checks and the SPA produces a deployable build.
- Given the repository layout, when GitHub discovers workflows, then both pipeline files are at the repository root and reference the actual application/script paths.
- Given production prerequisites, when an approved main release executes, then only the deployment job obtains AWS credentials and publishes its validated artifact.
- Given no AWS account, when the evaluator reads the submission, then prerequisites, required IAM scope, unverified integration behavior, and recovery commands are explicit.
- Given a failing new backend release, when the local deployment harness runs, then it verifies restoration of the old release and a nonzero deployment result.

## Spec Change Log

## Design Notes

Use Node.js 24, matching the installed local runtime; verify its supported status before binding workflow setup. No application framework is necessary for this pipeline exercise. Backend packaging uses a private S3 archive and SSM instead of adding ECR/Docker. A single EC2 restart has a brief interruption. Runtime configuration stays on the host. No database means no irreversible migration during rollback.

For the SPA, version filenames rather than overwriting assets. Publish HTML last, retain old hashed assets, and use CloudFront with a private S3 REST origin, HTTPS, and SPA fallback configured beforehand. Recovery republishes a retained artifact; publication and cache propagation are not globally atomic. GitHub environment approval rules and branch restrictions are setup prerequisites, not features created by workflow YAML.

## Verification

- Run backend and frontend package test/build commands locally.
- Run Bash syntax checks and a meaningful local backend recovery harness.
- Run actionlint and ShellCheck if available or obtain isolated local tooling; report any unavailable check.
- Inspect IAM documents as JSON and review workflow permission, event, concurrency, and artifact boundaries.
- Do not invoke AWS mutation APIs or claim a successful cloud deployment.

### Implementation evidence (2026-10-22)

- Linux Node 24.14.0 under WSL: both `npm ci` and package tests passed; frontend build passed with a full sample release SHA.
- `bash tests/releases.sh` passed real script execution with local AWS/systemd/curl doubles: activation, health/restart/stale-identity recovery, first-deployment failure, unsafe identifiers/archives, real host locking, SSM eventual consistency and terminal failure, execution of generated SSM commands, frontend ordering/retention/recovery/missing-archive/upload-failure cases.
- Bash syntax checks, ShellCheck 0.10.0, actionlint 1.7.7, six IAM JSON parses, and `git diff --check` passed. Action revisions verified against upstream refs with `git ls-remote`.
- No AWS operations or workflow runs performed. Cloud IAM/OIDC, actual systemd integration and CDN propagation remain unverified; setup assumptions and operational limitations are documented in `SOLUTION.md`.
- Independent adversarial and edge-case reviews found two patch-level backend defects: symlink startup skipped the entry point, and same-SHA recovery removed the active pointer. Both fixed with regression checks. Backend/frontend tests, deployment harness, ShellCheck and actionlint passed after fixes.

## Suggested Review Order

- Start with release boundaries, assumptions, setup and verification limits.
  [`SOLUTION.md:1`](../SOLUTION.md#L1)
- Inspect credential separation and production deployment guards.
  [`problem4-backend.yml:42`](../../../../.github/workflows/problem4-backend.yml#L42)
- Follow health-based activation and recovery on the host.
  [`deploy-backend.sh:30`](../scripts/deploy-backend.sh#L30)
- Review ordered static publication and CDN verification.
  [`release-frontend.sh:32`](../scripts/release-frontend.sh#L32)
- Check failed-release, recovery and concurrency evidence.
  [`releases.sh:26`](../tests/releases.sh#L26)
- Verify the real service entry point through a release symlink.
  [`server.test.mjs:25`](../backend/server.test.mjs#L25)
