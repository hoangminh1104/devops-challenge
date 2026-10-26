# Setup and release contract

## Separate host bootstrap

Prepare Linux amd64 EC2 with Docker Engine, Compose **v2.30+** (required for `env_file: format: raw`), AWS CLI v2 supporting S3 `PutObject --if-none-match`, SSM Agent, Bash, GNU tar/coreutils, util-linux `flock`. Node and npm are **not** required on the host. Allow SSM/S3 HTTPS through VPC endpoints or egress; no inbound SSH is needed. Give the instance `AmazonSSMManagedInstanceCore` plus [permissions-instance.json](permissions-instance.json). Templates assume SSE-S3; KMS needs additional grants.

The recorded demonstration uses private Amazon Linux 2023 x86_64 EC2 `i-008640a3549517bd1`, account `730335245469`, region `ap-southeast-1`. Docker, Compose, dependencies and the application were deployed and verified. See [LIVE.md](LIVE.md) for resources and evidence. The instructions below also describe prerequisites for a fresh environment.

Install [api.env.example](api.env.example) as `/etc/ship-api.env`, root:root, mode 0600; replace both password values with the same secret. Keep `DB_HOST=postgres`, `REDIS_HOST=redis`. `DB_USER`/`DB_NAME` default to `postgres`. Don't set `RELEASE_SHA` in this file: identity is baked into the image. Configure `CORS_ORIGIN` to the exact HTTPS SPA origin, with no path/trailing slash. This is a browser origin allowlist, not authentication. Runtime secrets never enter source, image or release archive.

Both production Compose files read this secret file in raw format: write literal values after `=` without surrounding quotes. Dollar signs, including `$NAME` and `${NAME}`, are preserved unchanged; quotes would also be literal. Do not source this secret file as shell code.

Install [deploy.env.example](deploy.env.example) as `/etc/ship-api-deploy.env`, root:root, mode 0600 under root-owned `/etc`. This separate file is **trusted Bash code**, sourced once with `set -a` before host paths/project selection, with settings exported to every Compose invocation, including rollback. Only root/trusted bootstrap operators may modify it; never populate it from release artifacts or application input. Persist host overrides here so fresh SSM shells use the same settings. For an ALB, set `API_BIND=0.0.0.0` here and restrict port 3000 to its security group. Keep `API_IMAGE` release-owned. To use the same network/env-file overrides during dependency bootstrap:

```bash
set -a
source /etc/ship-api-deploy.env
set +a
```

Install `compose.dependencies.yaml` to `/opt/ship-api/bootstrap/compose.dependencies.yaml`, then run once as root:

```bash
docker compose -p ship-api-data -f /opt/ship-api/bootstrap/compose.dependencies.yaml up -d --wait
```

This creates network `ship-api-data` and volume `ship-api-data_postgres-data`. PostgreSQL/Redis publish no host ports. Never run `down -v` on this project. Existing database password changes require deliberate database-side rotation; changing `POSTGRES_PASSWORD` does not rewrite an initialized volume. Redis is a disposable cache; only PostgreSQL durability is promised.

The recorded host uses existing NAT egress to download dependencies. On an isolated host, preload matching amd64 dependency images and installation packages through an authorized bootstrap transfer. Bootstrap bundles are separate from app releases; the instance policy template reads only `backend/*`, so grant any bootstrap object separately. Do not make application releases install packages or reset dependencies.

Production API Compose is **included in every backend artifact**; no preinstalled API Compose file is required. It joins the preexisting network, loads `/etc/ship-api.env` and defaults to localhost:3000. Put an HTTPS reverse proxy or load balancer in front. A private-only instance cannot serve a public S3 browser UI without reachable API ingress. An HTTPS SPA cannot call a plain HTTP API (mixed content); CORS alone does not fix routing/TLS.

## Artifact and deployment interface

Build/test/package from repository root on a Linux Docker builder:

```bash
export RELEASE_SHA=FULL_40_CHARACTER_SHA API_IMAGE=problem4-api:FULL_40_CHARACTER_SHA
docker build --load -f src/problem4/Dockerfile --build-arg RELEASE_SHA="$RELEASE_SHA" -t "$API_IMAGE" .
SKIP_BUILD=1 bash src/problem4/tests/docker.sh
bash src/problem4/scripts/package-backend.sh "$API_IMAGE" "$RELEASE_SHA" backend.tar.gz
```

Archive ordered members are exactly:

1. `image.tar`: Docker save of the tested image ID (no remote registry).
2. `RELEASE`: full commit SHA, newline terminated.
3. `IMAGE`: `sha256:` Docker image ID, newline terminated.
4. `compose.api.yaml`: production API service only.
5. `SHA256SUMS`: checksums of the first four members in that order.

Only one gzip layer surrounds the Docker save tar. Member checksums catch corruption; the outer archive SHA-256 passed by SSM binds the exact S3 bytes to those the deploy job observed. Image label and health both must match `RELEASE`. Checksums aren't signatures: protect S3 writers, workflow changes and host access. Backend and frontend SHA archive keys use conditional creation; a rerun producing different bytes fails rather than silently replacing a release. Byte-identical retries read back and compare the retained archive before deployment/publication. Retain original GitHub/S3 bytes for retries. Frontend smoke checks compare the complete served HTML and JS against the archive.

Normal runner entry point, after setting AWS region/credentials and `ARTIFACT_BUCKET`, `INSTANCE_ID`:

```bash
bash src/problem4/scripts/release-backend.sh release "$RELEASE_SHA" backend.tar.gz
```

It creates `s3://ARTIFACT_BUCKET/backend/SHA.tar.gz`, sends trusted checkout deployment code through SSM and polls terminal status. Recovery downloads the retained object first and sends its digest. An authorized operator may invoke the identical helper directly on the host after downloading the artifact:

```bash
ARCHIVE_SHA256=EXPECTED_64_HEX_DIGEST bash deploy-backend.sh /private/path/backend.tar.gz FULL_40_CHARACTER_SHA
```

Host defaults (also in `deploy.env.example`): `APP_ROOT=/opt/ship-api`, `API_PROJECT=ship-api`, `API_ENV_FILE=/etc/ship-api.env`, `DATA_NETWORK=ship-api-data`, `API_BIND=127.0.0.1`, `API_PORT=3000`. `/etc/ship-api-deploy.env` overrides inherited values for normal SSM releases and recovery; if absent, the defaults apply. `DEPLOY_ENV_FILE` selects an alternate trusted file for isolated tests/operator use. `HEALTH_ATTEMPTS=30`, `HEALTH_DELAY=2`, `LOCK_TIMEOUT=480` bound host waits. Root directory must be root-owned and not writable by the app. Keep trusted, reviewed Compose archives only; Compose can control the Docker host.

`releases/SHA/` retains Compose, image ID, release SHA and archive digest, not another large image tar. `current` points to the last healthy release; `previous` retains the last distinct recovery release. Images stay in Docker; don't prune known-good image IDs. Releases use `--no-deps --pull never api` and never invoke the bootstrap project. First failed deployment stops only API. Failed candidates return nonzero even after recovery. Health runs inside API with a bounded HTTP timeout and JSON checks, independently of external TLS routing. Abrupt host/process failure may require manual recovery; inspect SSM output and API logs before retrying.

## GitHub and AWS setup

Create environments `production-backend` and `production-frontend` with **main-only deployment branch rules**. Add required reviewers if supported by the GitHub plan; they are unavailable in the recorded deployment. OIDC environment subjects omit branch, so workflow guards alone aren't sufficient. Protect main and workflow/script changes. Substitute all placeholders in `trust-*.json` and `permissions-*.json`; use separate backend/frontend OIDC roles with audience `sts.amazonaws.com` and exact repository/environment subjects. SSM SendCommand is scoped to one instance and AWS-RunShellScript; GetCommandInvocation needs `Resource: "*"`. SSM runs as root and grants effective administrative control on that host.

Create private versioned artifact bucket, public access block, SSE-S3, TLS-only access and retention adequate for recovery. Keep archive writes tightly scoped. Both release roles have conditional publication and readback/recovery permission (`GetObject` and prefix-scoped `ListBucket` in the supplied policies); instance reads only backend archives. No application deploy role deletes S3 objects.

Create private site bucket + CloudFront S3 REST origin/OAC, default root `index.html`, HTTPS redirect and cache minimum TTL 0. Grant the distribution read access in site bucket policy. Configure 403/404 fallback to `/index.html` with low error-cache TTL. Set DNS/certificates externally. Frontend writes only `assets/*` and `index.html`; no sync/delete. Keep old hashed assets for cached HTML.

GitHub variables:

| Scope | Variables |
| --- | --- |
| Repository (build job needs it before protected deploy job) | `API_BASE_URL=https://api.example.com` (or ending `/api`) |
| Both production environments | `AWS_REGION`, `ARTIFACT_BUCKET`, application-specific `DEPLOY_ROLE_ARN` |
| production-backend | `INSTANCE_ID` |
| production-frontend | `SITE_BUCKET`, `DISTRIBUTION_ID`, `SITE_URL` |

`SITE_URL` is an HTTPS origin without trailing slash/path. The frontend build defaults to local `/api` for PR/local validation but main publication requires an HTTPS `API_BASE_URL`. Changing repo variables alone doesn't trigger a build: run a new frontend main release; recovery keeps the original API configuration. No static AWS keys are required.

## Local verification details

From `src/problem4`, with Linux Bash, Node 24 and Docker available:

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

These checks cover frontend behaviour/build output, release/recovery contracts, host orchestration, actual Docker integration and static configuration. Recorded deployment runs are linked in [SOLUTION.md](../SOLUTION.md#verification).

Docker integration uses unique Compose project/image names and ports 18304/18305; override `TEST_API_PORT`/`TEST_WEB_PORT` if occupied. Its cleanup removes only that project's containers and test volume; images remain for inspection/reuse. `KEEP_DOCKER_TEST=1` retains containers/temp metadata for diagnosis. All generated secret/env files are outside the checkout.

On Windows, invoke Linux scripts through WSL with Linux Node 24 on PATH; Docker CLI must address the same Linux engine as native Docker Desktop. Tests use no host bind mounts, avoiding Linux/Windows bind-path ambiguity. Run local `docker compose` from native PowerShell or WSL. No global Docker prune/reset commands are used.
