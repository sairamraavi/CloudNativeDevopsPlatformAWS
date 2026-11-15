# Production planning inputs

These configurations are a provisional sizing baseline derived from staging. Review network overlap, peak CPU/memory, media traffic, availability objectives, regional versions, quotas and budget before provisioning.

| Stack | Proposed configuration |
| --- | --- |
| [Persistent data](../../Terraform/prod-data/) | Private versioned S3 media bucket, TLS-only access, CORS for the supplied hostname, ACM certificate and production application secret metadata. Manage database credentials separately. |
| [Cluster foundation](../../Terraform/environments/prod/) | Dedicated 10.2.0.0/16 VPC by default, two supplied AZs, per-AZ NAT, EKS 1.36, one on-demand t3.large worker per zone initially and up to two per zone. Worker types and VPC CIDR can be overridden. Control-plane log retention is 30 days. Includes workload IAM, EBS CSI and Metrics Server. |

### Prepare plans later

On the Mac, from the repository root, export AWS_PROFILE, AWS_REGION, TF_VAR_expected_account_id and CAPSTONE_STATE_BUCKET for the intended production account. Use its initialized bootstrap bucket. Set TF_VAR_application_domain to the production hostname you control, then run:

```bash
bash scripts/prod/plan.sh data
```

The script checks identity and bucket ownership, initializes a dedicated S3 state key and saves a private plan outside Git. Planning does not create the data resources. After a separately approved data deployment, use its actual media_bucket_arn and application_prod_secret_arn outputs for TF_VAR_media_bucket_arn and TF_VAR_application_secret_arn. Set TF_VAR_availability_zones to a JSON array of two distinct regional AZs, TF_VAR_eks_admin_role_arn to the approved role ARN, and TF_VAR_eks_public_access_cidrs to a JSON array of approved /32 addresses. Then run:

```bash
bash scripts/prod/plan.sh cluster
```

Both commands stop after planning. State keys are prod-data/terraform.tfstate and environments/prod/terraform.tfstate. The proposed cluster has no Jenkins promotion grant. Before going live, establish a dedicated release identity and approval, validate DNS/TLS, Atlas isolation and restore, install controllers and monitoring, and test application rollout, failure recovery and rollback with production-specific values. The existing automatic Jenkins path ends at staging.
