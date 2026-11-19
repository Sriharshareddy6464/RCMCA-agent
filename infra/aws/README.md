# AWS deployment foundation

This Terraform stack describes the production path: private encrypted RDS PostgreSQL with PostGIS, multi-AZ ElastiCache Redis, public HTTPS ALB, ECS Fargate API/OSRM/municipal-sync/vision-worker services, ECR, a private evidence bucket with CloudFront OAC, and task IAM access to Secrets Manager, S3, and Amazon Bedrock. It has **not** been applied to an AWS account.

## Prerequisites

- Terraform 1.6+, AWS CLI, Docker, an AWS account/profile, and a domain with an ACM certificate in `ap-south-1`.
- `osrm-data/hyderabad.osrm*` produced by the local Phase 1 preparation step.
- A local `models/road_damage.onnx` artifact. It is a pothole-only starter and must be validated before field use.
- Unique deployment tag for immutable image repositories.
- Decide which browser origins need S3 PUT CORS. Native Flutter requests do not depend on browser CORS enforcement.

## Build and deploy

1. In `infra/aws`, run `terraform init`, then create only ECR and the empty evidence bucket with a targeted apply (`-target=aws_ecr_repository.app -target=aws_s3_bucket.evidence`). This stage does not start application tasks or provision RDS/Redis.
2. From repository root, run `scripts/push_aws_images.ps1 -AwsAccountId <account-id> -AwsRegion ap-south-1`. The script builds and pushes the API image and an OSRM image containing the locally prepared Hyderabad graph, then uploads the ONNX model to the private evidence bucket.
3. Obtain a domain and issue an ACM certificate in `ap-south-1`, then copy `production.tfvars.example` to `production.tfvars` and replace every placeholder with actual immutable image URIs, `deploy_services = true`, the certificate ARN, `vision_model_key = "models/road_damage.onnx"`, explicit `allowed_ingress_cidrs`, your allowed web origins, and any authorized municipal export URLs. The ALB CIDR list defaults to empty because this API does not yet require authentication; do not open it broadly for field trials. Terraform blocks task deployment unless the certificate, built application images, and explicit restricted ingress CIDRs are supplied.
4. Run `terraform plan -var-file=production.tfvars` and review cost, region, ingress CIDRs, capacity, and destruction/replacement actions. Then run `terraform apply -var-file=production.tfvars` when an account owner authorizes provisioning.
5. The API applies the idempotent PostGIS schema and versioned migrations on startup. ECS uses the RDS-managed master secret; application tasks read it through task-role IAM. The Bedrock provider uses `qwen.qwen3-32b-v1:0` by default and requires model access in the chosen account and region.
6. Configure the Flutter release build with the resulting HTTPS `api_url`; complete Google Play/internal field validation only after app signing and privacy disclosures are ready.

The stack deliberately defaults to two AZs, Multi-AZ RDS, two Redis nodes, two API tasks, and two OSRM tasks. These resources incur ongoing costs. The task-role permissions are scoped to this app's S3 paths and RDS secret; Bedrock invocation is currently allowed against all model ARNs and should be narrowed once the account's selected model ARN is confirmed.

The development AWS account was queried read-only in `ap-south-1`: no issued ACM certificate, ECR repositories, ECS clusters, or Route 53 hosted zones were present. A no-refresh Terraform plan currently proposes 48 additions and no updates or destroys; no plan was applied. PostgreSQL 16.15 and `db.t4g.medium` are available in the region. The deployed API cannot be exposed until a domain certificate, immutable image URIs, and explicit restricted client CIDRs are supplied. Terraform keeps ALB ingress closed by default and checks these deployment inputs before starting tasks.

## Model deployment constraint

The local Phase 2 model is Qwen2.5-3B-Instruct-AWQ; this stack selects the managed Bedrock Qwen3 32B model because the Qwen2.5-3B model is not listed among Bedrock's hosted Qwen models. This changes model size and behavior and must be evaluated for cost, latency, structured-output compatibility, and multilingual performance before production. Bedrock's Qwen3 32B model is listed for `ap-south-1`; no SageMaker endpoint is provisioned by this stack.

## Known deployment follow-up

- Terraform provider initialization and `terraform validate` succeeded in the development environment. Repeat both in the deployment environment after any infrastructure changes.
- The app is stateless with database persistence, but no custom domain/Route 53 record, WAF, autoscaling policies, alerting dashboards, or CI/CD pipeline is provisioned here.
- The municipal worker remains idle unless authorized feeds are configured.
- The included model exposes only pothole detections; model artifact provenance and severity calibration are documented under `models/README.md`.
