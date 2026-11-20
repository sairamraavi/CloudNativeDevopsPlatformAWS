# Develop configuration completion patch — audit and application notes

## Scope
This patch targets **develop only**. It does not provision AWS resources and does not touch staging or production. It uses the supplied `phase2-step2-develop-healthcheck-fixed.sh` as the baseline for the active orchestration script.

## Changes in this patch
1. `phase2-step2-develop.sh` is based on the healthcheck-fixed script: bounded HTTP/TCP/Mongo readiness checks replace immediate checks.
2. Bootstrap Terraform is not initialized/applied by the orchestration script. The state bucket already exists, but `bootstrap/terraform.tfstate` was not found. Bucket ownership is not established; creating/importing/managing it now would be unsafe.
3. The persistent Terraform root no longer declares ECR. Existing ECR repositories are owned by the separate `shared/ecr.tfstate` state. This avoids attempting to create duplicate repositories from `persistent/terraform.tfstate`.
4. AWS region defaults in bootstrap, persistent and dev roots are corrected to `ap-southeast-2`.
5. Monitoring region references are corrected to Sydney.
6. The script no longer reads `alb_logs_bucket_name`: no resource or output with that name exists in the supplied source. ALB access-log bucket provisioning/integration remains incomplete.

## Confirmed facts from supplied material
- AWS account target: `529976312668`; region target: `ap-southeast-2`; profile: `personal`.
- State bucket: `streamingapp-tfstate-8a4b578417838a617bba947a4f`.
- `shared/ecr.tfstate` exists and owns the five application ECR repositories.
- `bootstrap/terraform.tfstate`, `persistent/terraform.tfstate`, and `environments/dev/terraform.tfstate` were not found in the supplied inspection output. Missing state is not proof that corresponding AWS resources do not exist.
- Existing local `terraform.tfstate` in the archive is empty and is not proof of deployed infrastructure.
- Healthcheck-fixed script includes retries for frontend/auth/streaming/admin, TCP readiness for Chat, and Mongo ping.

## Must resolve before applying Terraform
### A. Existing resource ownership for persistent root
The persistent state key is absent. Before applying its plan, inventory whether these resources already exist in the account/region: the media bucket, Secrets Manager secret `streamingapp-capstone/dev/application`, and ACM certificate for `streaming.sairamraavi.com`. If any exist, do not apply a plan that creates replacements; import them into the intended persistent state only after verifying ownership and exact resource IDs.

### B. Bootstrap state
Do not run `terraform apply` in `Terraform/bootstrap` and do not use `terraform init -migrate-state` against the existing bucket until the bucket's actual owner/state is identified. This patch deliberately leaves bootstrap state untouched.

### C. ALB access logs
The setup guide and old script expect `alb_logs_bucket_name`, but the supplied Terraform source has no ALB log bucket resource/output. The patch removes the invalid output lookup; it does not invent a bucket or claim ALB logging is configured. Add a properly secured bucket, ALB log-delivery policy, and ingress/controller integration as a separate reviewed change.

### D. Remaining hardcoded account-specific values
`Monitoring/cluster-autoscaler-values.yaml` contains an IAM role ARN for account `175200623108`, while the target account is `529976312668`. This is not changed automatically because the correct role name/ARN must be confirmed from the Terraform output. Replace it with the actual autoscaler role ARN output after the dev stack is deployed.

The Alertmanager SMTP sender address and SES SMTP credentials are also environment-specific. The placeholder credentials must be provisioned securely; do not commit credentials.

### E. Setup guide drift
`setup-process.md` still contains Mumbai AZ values (`ap-south-1a`, `ap-south-1b`) and refers to persistent ECR creation and an ALB logs bucket that do not match this ownership model/source. Use the script's dynamic Sydney AZ discovery and the patch notes instead.

## Validation status
The patch was assembled by static inspection of the uploaded ZIP and scripts. Terraform, Helm and Ansible binaries are not installed in the review container, so no claim is made that `terraform fmt`, `validate`, `plan`, Helm lint, or Ansible syntax checks passed. Run the consolidated WSL validation block supplied with this patch before any apply.

## State safety
Never delete `.tfstate`, `.tflock`, `.terraform`, plan files or ECR repositories as a cleanup step. Never run `terraform destroy`. Do not re-create or import ECR resources: they are already managed by `shared/ecr.tfstate`.
