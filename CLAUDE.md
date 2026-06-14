# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a CloudFormation **infrastructure-only** repository for a containerized Java To-Do application deployed on AWS ECS Fargate. Application code lives in a separate repository. Infrastructure is deployed via **CloudFormation GitSync** — the `deployment-file.yaml` at the repo root is the GitSync entry point.

The application stores data in **RDS PostgreSQL** accessed through **RDS Proxy** for connection pooling, and uses **ElastiCache Redis** to accelerate read-heavy todo list queries.

---

## First-time Setup

After cloning, run once to activate git hooks:
```bash
./setup.sh
```

This configures a pre-push hook that automatically syncs changed child stack templates to S3 before every `git push`.

---

## Common Commands

**Lint templates:**
```bash
cfn-lint <template>.yaml
```

**Validate a template:**
```bash
aws cloudformation validate-template --template-body file://<template>.yaml
```

**Package nested stacks** (upload child templates to S3 and rewrite refs):
```bash
aws cloudformation package \
  --template-file root-stack.yaml \
  --s3-bucket <deployment-bucket> \
  --output-template-file packaged.yaml
```

**Deploy manually (for testing, not production):**
```bash
aws cloudformation deploy \
  --template-file packaged.yaml \
  --stack-name bem15-todo-app \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides GithubOrg=wodoame GithubAppRepo=BEM15-todo-app Environment=production
```

---

## Nested Stack Architecture

```
root-stack.yaml
├── stacks/network.yaml          # VPC, 3-tier private subnets (ECS/DB/Cache), IGW, route tables, VPC endpoints
├── stacks/security.yaml         # Security groups: ALB, ECS, RDS Proxy, RDS, ElastiCache
├── stacks/ecr.yaml              # ECR repository for the application image
├── stacks/database.yaml         # RDS PostgreSQL, RDS Proxy, Secrets Manager secret
├── stacks/cache.yaml            # ElastiCache Redis cluster in dedicated subnets
├── stacks/iam.yaml              # GitHub OIDC provider, ECS roles, CodeDeploy/Pipeline/EventBridge roles
├── stacks/compute.yaml          # ECS cluster, task definition, ECS service, ALB + target groups
├── stacks/autoscaling.yaml      # ECS auto scaling (1 min / 1 desired / 4 max, CPU-based)
└── stacks/cicd.yaml             # CodePipeline, CodeDeploy (blue/green), EventBridge rule
```

**Dependency order** (root-stack passes outputs as parameters to each child):
1. `network` → no dependencies
2. `security` → needs VPC ID from `network`
3. `ecr` → no dependencies
4. `database` → needs DB subnet IDs and RDS/Proxy security group IDs from `network`/`security`
5. `cache` → needs cache subnet IDs and ElastiCache security group ID from `network`/`security`
6. `iam` → needs ECR repo ARN and DB secret ARN
7. `compute` → needs subnets, security groups, proxy endpoint, Redis endpoint, DB secret ARN
8. `autoscaling` → needs ECS cluster and service name from `compute`
9. `cicd` → needs ECR repo, ECS cluster/service, ALB listener/target groups from `compute`

---

## Key Design Decisions

- **GitSync entry point**: `deployment-file.yaml` references `root-stack.yaml` as the top-level template.
- **Subnet layout**: Three tiers of private subnets — ECS (10.0.11-12.0/24), RDS/Proxy (10.0.21-22.0/24), ElastiCache (10.0.31-32.0/24). Each tier has its own route tables.
- **RDS Proxy**: ECS tasks connect to the RDS Proxy endpoint, not directly to RDS. The proxy authenticates via Secrets Manager and pools connections to PostgreSQL.
- **Security group chain**: ALB → ECS → RDS Proxy → RDS (port 5432). ECS → ElastiCache (port 6379). No direct ECS-to-RDS path.
- **ECS networking**: Tasks in private ECS subnets; ALB in public subnets. VPC endpoints for ECR (API + DKR), S3 (gateway), CloudWatch Logs, and Secrets Manager keep all traffic off the public internet. No NAT Gateway.
- **Secrets Manager endpoint**: Extended to DB subnets so the RDS Proxy can retrieve credentials at startup.
- **Blue/green**: CodeDeploy manages traffic shifting. The `appspec.yaml` and `taskdef.json` are produced by the app CI pipeline (separate repo) and stored as CodePipeline artifacts.
- **OIDC auth**: GitHub Actions authenticates to AWS via an IAM OIDC provider — no stored credentials.
- **Auto scaling**: Min 1, desired 1, max 4 tasks. Scale-out at CPU ≥ 70% for 2 minutes; scale-in at CPU ≤ 30% for 5 minutes.

---

## Repository Layout

```
root-stack.yaml          # Parent stack; references all child stacks via S3 URLs
deployment-file.yaml     # CloudFormation GitSync configuration
stacks/                  # Child stack templates
diagram/                 # Architecture diagram (.drawio)
cfn-service-role-policy-compute.json    # CFN execution role policy (IAM, ECS, CI/CD)
cfn-service-role-policy-networking.json # CFN execution role policy (VPC, RDS, ElastiCache)
```
