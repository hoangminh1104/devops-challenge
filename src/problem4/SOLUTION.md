# Problem 4 — Ship It Twice

## Assumptions and why

- **Problem 3 is the backend source.** I reused its API directly and added a minimal static frontend to demonstrate the complete product.
- **One private EC2 instance runs the API, PostgreSQL, and Redis.** Docker Compose keeps the exercise small, while a persistent volume preserves PostgreSQL data across application releases.
- **Infrastructure and runtime secrets are configured separately.** Release pipelines update applications without provisioning networks, resetting dependencies, or embedding secrets in artifacts.
- **Backend and frontend release independently from `main`.** API changes must remain backward-compatible with the currently deployed frontend.

## How the pipelines work

The [backend workflow](../../.github/workflows/problem4-backend.yml) and [frontend workflow](../../.github/workflows/problem4-frontend.yml) validate pull requests without production credentials. Relevant pushes to `main` deploy only after validation passes.

### Backend: Docker to EC2

1. Build a non-root Node.js image from the shared Problem 3 API using locked dependencies.
2. Test the image with real PostgreSQL and Redis, including dependency failures, failed-image rollback, and data persistence.
3. Package the tested image, release identity, Compose configuration, and checksums. Transfer that exact artifact to the deployment job and archive it in S3 under its commit SHA.
4. Use SSM to download and verify the archive on EC2, then replace only the API container.
5. Check the expected release SHA and dependency health. If activation fails, restore the previous image and report the deployment as failed.

### Frontend: static files to S3

1. Test and build the SPA with its API URL, then retain the output as a release archive.
2. Upload content-hashed JavaScript before HTML and preserve older assets for cached pages.
3. Invalidate CloudFront and compare the publicly served HTML and JavaScript with the expected files.

Both pipelines use temporary AWS credentials through OIDC, separate scoped roles, revision-pinned actions, deployment serialization, and timeouts. Existing release keys reject different archive bytes. Manual workflow dispatch restores retained releases without rebuilding.

## Verification

Both normal build/deployment pipelines passed, including real Docker integration tests and AWS OIDC authentication:

- [Backend build and deployment](https://github.com/hoangminh1104/devops-challenge/actions/runs/40091688144)
- [Frontend build and deployment](https://github.com/hoangminh1104/devops-challenge/actions/runs/40091688188)

Deployment to the intended sandbox, `730335245469`, also passed through both recovery workflows:

- [Backend recovery deployment](https://github.com/hoangminh1104/devops-challenge/actions/runs/40102712342)
- [Frontend recovery deployment](https://github.com/hoangminh1104/devops-challenge/actions/runs/40102752393)

Public checks confirmed frontend delivery, healthy PostgreSQL/Redis, and database responses. Failed-image rollback was tested in isolation, without deliberately breaking the live application.

Demo: **https://d1v3sagma6ldre.cloudfront.net**

## Deliberately left out

- Infrastructure as code, multi-instance availability, autoscaling, and zero-downtime deployment.
- Database migrations, backups/restores, and database rollback.
- Monitoring infrastructure, artifact signing, release cleanup, and automated frontend rollback.
- TLS between CloudFront and the ALB; browser traffic uses HTTPS.

API replacement briefly interrupts requests. Application rollback does not reverse database changes. Main-only deployment restrictions are configured, but required-reviewer gates are unavailable under the current GitHub plan, so successful main releases deploy automatically.

Setup, resource details, and cleanup instructions are in [deploy/README.md](deploy/README.md) and [deploy/LIVE.md](deploy/LIVE.md).
