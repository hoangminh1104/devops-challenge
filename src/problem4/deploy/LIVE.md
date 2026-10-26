# Live deployment and verification

Demo: **https://d1v3sagma6ldre.cloudfront.net**

Recorded verification: 2026-10-24. Account `730335245469`, region `ap-southeast-1`, CLI profile `AWSAdministratorAccess-730335245469`. These identifiers describe the recorded deployment, not a guarantee that resources remain available indefinitely.

## Resources

| Resource | Name / ID |
| --- | --- |
| Private EC2 | `dom7hc-deploy-api`, `i-008640a3549517bd1`, `10.0.3.32`, no public IP |
| Instance security group | `sg-00a01ec480d135bd9` |
| ALB | `dom7hc-deploy-api-alb` |
| ALB security group | `sg-0292c77b3d0fee73a` |
| Target group | `dom7hc-deploy-api-tg` |
| CloudFront | `E2O9Y4TM36JCJD` |
| Origin access control | `E14QQN2LYVQ5LF` |
| Custom cache policy | `90177b56-5124-4f81-a3a9-dbe929983307` |
| Site bucket | `dom7hc-deploy-web-730335245469-ap-southeast-1` |
| Artifact bucket | `dom7hc-deploy-artifacts-730335245469-ap-southeast-1` |
| Instance role / profile | `dom7hc-deploy-ssm-role` / `dom7hc-deploy-instance-profile` |
| GitHub roles | `dom7hc-deploy-github-backend`, `dom7hc-deploy-github-frontend` |

CloudFront serves private S3 objects through OAC and forwards `/api/*` uncached to the ALB. The ALB accepts CloudFront origin-facing addresses and requires a secret origin header. EC2 port 3000 accepts only the ALB security group. Browser traffic uses HTTPS; the CloudFront-to-ALB hop uses HTTP.

The deployment reuses existing VPC `vpc-0740b5d72e77fd95d`, private subnet `subnet-0ba473a4e68da3914`, public subnets `subnet-0737b59145b2d295e` and `subnet-0900e0f4a620b8360`, and NAT Gateway `nat-0199882a7b068a387`. No shared routes were changed. SSM and image downloads use the existing NAT egress.

## Evidence

- [Backend build/deployment](https://github.com/hoangminh1104/devops-challenge/actions/runs/40091688144) and [frontend build/deployment](https://github.com/hoangminh1104/devops-challenge/actions/runs/40091688188) passed for source `9ca597f938f565117b44227be08f0bfa61ad7dde`, including OIDC and real Docker integration/recovery tests.
- Subsequent deployment to this sandbox passed through [backend recovery](https://github.com/hoangminh1104/devops-challenge/actions/runs/40102712342) and [frontend recovery](https://github.com/hoangminh1104/devops-challenge/actions/runs/40102752393). The backend reused the exact tested image archive. The frontend was rebuilt from the same source with its new API URL before archiving; it was not a byte-identical copy of the previous environment's build.
- Public HTTPS checks confirmed frontend identity, healthy PostgreSQL/Redis, and database time. The new database contains fresh demo data; no database migration was performed.

GitHub environments `production-backend` and `production-frontend` have main-only branch restrictions and the variables listed in [README.md](README.md). Repository `API_BASE_URL` points to the demo origin. Required-reviewer gates are unavailable under the current GitHub plan; successful main releases deploy automatically.

## Manual verification

Open the demo and click Refresh. In AWS, inspect the ALB target group, S3 objects, CloudFront invalidations and SSM Run Command history. To inspect the API directly, connect to the EC2 instance through Session Manager and run:

```bash
curl -fsS http://127.0.0.1:3000/api/health
curl -fsS http://127.0.0.1:3000/api/users
sudo docker ps
```

Check the release SHA and both dependency fields, not only HTTP status. For archived recovery, dispatch the relevant GitHub workflow from main with a retained full `release_sha`; this changes the running application.

## Cleanup ownership

EC2/EBS, ALB, S3 and CloudFront incur ongoing charges. After preserving data and disabling or retargeting workflows, delete only this deployment's distribution/OAC/cache policy, ALB/listeners/target group, instance/root volume, two custom security groups, versioned buckets and deployment IAM roles/profile.

**Preserve the preexisting VPC, subnets, NAT Gateway, internet gateway and route tables.** Check whether the GitHub OIDC provider is shared before removing it. S3 cleanup must include all versions and delete markers.
