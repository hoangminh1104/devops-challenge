# Live end-to-end test environment

Verified 2026-10-24. AWS account `516418317632`, region `ap-southeast-1`, CLI profile `AWSAdministratorAccess-516418317632`.

Open **https://d34e7lkj3dq7h3.cloudfront.net**. The static UI calls `/api/health` and `/api/users` on the same HTTPS origin. CloudFront serves static objects from private S3/OAC and forwards `/api/*` uncached to the ALB. No custom domain or browser CORS configuration is needed. The ALB origin hop is HTTP; this lab does not claim end-to-end origin TLS. ALB ingress allows the CloudFront origin-facing managed prefix list only, and its listener requires a generated origin header; other requests receive 403. That header is kept out of the repository.

## Resources to watch

| AWS console | Resource |
| --- | --- |
| CloudFront | `E3NTN25OYYWKBB`, comment `dom7hc-deploy-web` |
| S3 static site | `dom7hc-deploy-web-516418317632-ap-southeast-1` |
| S3 release artifacts | `dom7hc-deploy-artifacts-516418317632-ap-southeast-1` |
| EC2 API | `dom7hc-deploy-api`, `i-06a3a1ca8845a1087`, private `10.77.0.44` |
| ALB | `dom7hc-deploy-api-alb` |
| Target group | `dom7hc-deploy-api-tg` |
| NAT instance | `dom7hc-deploy-nat`, `i-053d94abf8afe7e0b`, t3.small |
| VPC | `vpc-0d06fba9047838687` |
| Private subnet | `subnet-0e31f973f78c6d580` |
| Public subnets | `subnet-0745881cb6fa7e2bd`, `subnet-0720d7579008e09bb` |
| Public route table | `rtb-0d7620e8842a807bb` |
| Internet gateway | `igw-0d37756c5987fb51c` |
| ALB security group | `sg-0b5c059834db83720` |
| NAT security group | `sg-0341de45a7cc1bfad` |

The private API has no public IP. It now has outbound HTTPS via the dedicated NAT instance, permitting Docker image/package downloads. NAT Gateway provisioning failed because the account Elastic IP quota was full; no existing addresses were altered. NAT initially exhausted memory at t3.nano during package installation and was resized to t3.small. IP forwarding, MASQUERADE and disabled source/destination checking are configured. This is a single-host lab egress dependency, not HA production networking.

## What actually passed

- Real `tests/docker.sh` on private EC2, SSM command `457c36c0-6c9d-41ce-8df7-14f04727f75b`: direct/proxied HTTP, nonroot API, CORS, PostgreSQL/Redis outages, exact-image packaging/activation, failed-image recovery, unchanged dependency containers, persisted SQL state across API rollback and database recreation, host lock, graceful shutdown. Exit 0. Log: `/opt/p4-validation/docker-test.log`.
- Separate persistent deployment: command `638d7165-1001-4c1e-802e-136e754637af`, exit 0. API image `sha256:29e00cd545be63d4c9abb5cda82e15c94e108a151ee9bd046b8652b4fce0267e`.
- HTTPS public checks: frontend HTTP 200, `/api/health` status ok with both dependencies healthy, `/api/users` returns PostgreSQL timestamp.
- Bootstrap identity is **`aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa`**, deliberately a test identifier, not a committed source SHA. Code is still uncommitted. Both archived bootstrap releases exist in S3; future GitHub releases use real commit SHAs.
- No GitHub workflow or OIDC exchange has run yet. No browser automation was available; public HTTP/API checks passed, UI behavior is covered by Node tests and can be checked manually at the URL.

## GitHub configuration already created

Repository `hoangminh1104/devops-challenge` has environments `production-backend` and `production-frontend`, each restricted to branch `main`; AWS variables and role ARNs are configured. Repository `API_BASE_URL` points at the same CloudFront HTTPS origin. Roles `dom7hc-deploy-github-backend` and `dom7hc-deploy-github-frontend` use GitHub OIDC with repository/environment-scoped subjects and separate permission policies. Both legacy and immutable repository subject formats are explicitly restricted to this repository and environment.

**Required-reviewer gates are unavailable on the repository's current billing plan** (GitHub API 422). Therefore deployments from main are automatic after CI, without environment approval. Main-only environment branch rules are active. Configure a supported plan if mandatory human approval is required; YAML alone does not provide it. Commit/push approval has not yet been given, so workflow files remain local. Active GitHub token has repo access but lacks workflow scope; pushing new workflow files may additionally require updating authentication.

## Manual test

1. Open the CloudFront URL, confirm dependency state and database time; press Refresh.
2. In EC2, select `dom7hc-deploy-api` → Connect → Session Manager. Run:

```bash
curl -fsS http://127.0.0.1:3000/api/health
curl -fsS http://127.0.0.1:3000/api/users
sudo docker ps
```

3. Once code is committed/pushed with owner approval, inspect **Actions → Problem 4 backend/frontend**. PR runs only validate; main runs deploy. In AWS watch artifact keys, SSM Run Command output, ALB target health and CloudFront invalidations.
4. For recovery, run the relevant workflow on main with a retained SHA. Initial test identity above is retained, but prefer real known-good GitHub release SHAs after the first workflow deployment.

## Charges and cleanup

Two EC2 instances/EBS, a public IPv4 address, ALB and three SSM interface endpoints incur ongoing charges; S3/CloudFront incur storage/requests/transfer. No NAT gateway/EIP was allocated. Stopping the API alone does not stop ALB/endpoint/storage charges.

With owner approval: preserve database data; disable/delete CloudFront then OAC/custom cache policy; delete ALB/listeners and target group; terminate API and NAT instances; delete SSM/S3 endpoints; empty all versions/delete markers before deleting the two buckets; detach/delete custom IAM roles/policies/profile; remove custom security groups, route associations/routes/subnets, detach/delete IGW and delete VPC. Remove GitHub environment variables/environments separately. Do not delete unrelated account resources.
