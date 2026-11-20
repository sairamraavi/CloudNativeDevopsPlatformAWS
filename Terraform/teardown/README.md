# Teardown plan and decommissioning order

Use this workflow when an environment is no longer needed. The [plan generator](plan.sh) produces a **Terraform destroy preview** for one account, region and environment. A saved binary plan is specific to the live state and can contain sensitive values. Generate it privately when reviewing an actual retirement. The supported roots are dev and staging. Production has plan-only infrastructure configuration and needs its own ownership and recovery review before any future retirement.

### 1. Select the environment

On the Mac, from the repository root, authenticate the intended AWS profile. Set AWS_PROFILE, AWS_REGION, TF_VAR_expected_account_id and CAPSTONE_STATE_BUCKET from the intended deployment record. Supply the same Terraform input values used to provision the environment, either through TF_VAR variables or a private tfvars file. The default backend metadata directory is under `~/.capstone/<account>/<region>/<environment>/data`; set TF_DATA_DIR explicitly for another initialized location. The script checks the STS identity, cached S3 backend bucket/key/region and workspace before planning.

### 2. Estimate the retirement scope

```bash
bash Terraform/teardown/plan.sh staging /absolute/path/to/private-staging.tfvars
```

Choose dev for the development stack. Omit the file argument when all required inputs are already exported. Terraform reads current resources and briefly locks state. It writes the binary plan beneath the selected environment's private plans directory and prints its path. Inspect the printed plan or use `terraform show /absolute/path/to/teardown.tfplan` privately. Check the VPC, cluster, node groups, IAM and controller dependencies. Kubernetes-created ALBs and volumes, Atlas and Cloudflare resources require separate ownership checks.

### 3. Prepare for an approved retirement

- Pause incoming deploys and record the release, Git revision, environment and current Terraform outputs. Check whether staging still relies on the dev Jenkins controller and role before retiring dev.
- For dev, follow the [checkpoint workflow](../../Docs/dev-lifecycle.md). Verify Jenkins/SonarQube archives and monitoring snapshots. Confirm an independent recoverable Atlas backup if data will be affected. The dev runner is scoped to dev; staging needs its own backup and rollback decision.
- Inventory Ingresses, load balancers, claims, reclaim policies, volume IDs and DNS/Atlas entries for this environment. Remove application resources while their controllers still run. Verify ALB deletion; remove approved claims only after confirming retention and backups. Wait for volume cleanup before removing the CSI/controller infrastructure.
- **Manual approval required for deletion.** For a dev session, use the documented checkpoint-aware down operation, which creates its own fresh plan. For a separately reviewed environment retirement, regenerate and review the plan after workload cleanup. A preview generated before cleanup is a planning aid. Keep bootstrap, persistent/staging-data state, media history, release images and recovery artifacts under their own retention decisions.

### 4. Verify completion and costs

After an authorized teardown, inspect the selected environment's state. Check EC2, NAT gateways, load balancers, unattached volumes, snapshots, public IPv4, log groups and separate clusters. Remove stale application DNS and Atlas allowlist entries only for the retired environment. Keep ACM validation records for retained certificates. Check retained S3 versions, ECR, CloudWatch and Atlas costs using the [cost guide](../../Docs/dev-cost-and-scope.md). Empty Terraform state alone cannot establish zero spend.
