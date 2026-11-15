# Session boundaries, retained data and cost controls

**Verified historically:** manual dev removal and recreation, empty dev Terraform state, CI/host archive integrity, restored Jenkins and SonarQube. **Implemented but not fully verified:** the combined automated checkpoint → down → up cycle. Atlas data backup and isolated database restore remain pending.

Use [dev lifecycle automation](dev-lifecycle.md) first. It depends on the original account, region, private checkpoint directory, SSH identity, Terraform state and retained images, snapshots and external-service access. Starting an EC2 instance alone does not restore the cluster. Switching to a personal AWS account requires separate state, resource identifiers, images, DNS and service identities.

| Owner | While running | After dev teardown or ordinary stop |
| --- | --- | --- |
| Dev Terraform | EKS control plane, managed worker instances, Jenkins EC2, NAT gateways, public IPv4 and log storage | Verify cluster, nodes and gateways were deleted. Stopping just Jenkins leaves EKS, worker nodes, gateways and load balancing active. EBS volumes can survive a stopped instance. |
| Kubernetes controllers | ALB and encrypted EBS volumes provisioned for claims | Remove app Ingress/release before the controller. Preserve required data before deleting PVCs with Delete reclaim policy. Verify the actual ALB and recorded volume IDs disappear before VPC teardown. |
| Persistent Terraform | S3 media, object versions and ALB logs, ECR images, Secrets Manager | Retained across sessions; storage and related usage can continue. Removing old image digests or media versions can invalidate restore or playback. |
| Backup and bootstrap | Monitoring snapshots, versioned state, private Jenkins backups and SonarQube dump | Retain a verified recovery point. Loss of the state bucket breaks resource ownership tracking; loss of Jenkins home or its keys can make stored credentials unrecoverable. |
| Separate staging / Atlas | Staging EKS, network and application data; Atlas database and plan | Dev shutdown does not shut these down. Dev teardown can also remove the shared Jenkins host that staging promotion relies on. Atlas has a separate billing and backup lifecycle. |

### Before and after a session

**Mac, repository root; read-only example.** Set AWS_PROFILE and AWS_REGION for the intended account. Inspect the account, region, clusters and live cost drivers. Results span that account and region; correlate names, VPC and project tags with the state before attributing costs.

```bash
aws sts get-caller-identity --profile "$AWS_PROFILE" --query Account
aws configure get region --profile "$AWS_PROFILE"
aws eks list-clusters --region "$AWS_REGION"
aws ec2 describe-nat-gateways --region "$AWS_REGION" --filter Name=state,Values=available --query 'NatGateways[].[NatGatewayId,VpcId]'
aws elbv2 describe-load-balancers --region "$AWS_REGION" --query 'LoadBalancers[].[LoadBalancerName,VpcId]'
aws ec2 describe-volumes --region "$AWS_REGION" --filters Name=status,Values=available --query 'Volumes[].[VolumeId,Size]'
aws ec2 describe-snapshots --region "$AWS_REGION" --owner-ids self --query 'Snapshots[].[SnapshotId,VolumeSize,StartTime]'
```

**Mac, any directory; read-only billing example.** With Cost Explorer access and the intended profile selected, set START_DATE and END_DATE to ISO dates (end exclusive). This shows reported account usage by service; credits, taxes, late-arriving usage and non-project resources affect interpretation. No historical invoice or project-specific dollar total was supplied.

```bash
aws ce get-cost-and-usage --region us-east-1 --time-period "Start=$START_DATE,End=$END_DATE" --granularity DAILY --metrics UnblendedCost --group-by Type=DIMENSION,Key=SERVICE
```

**Manual approval required:** the down operation removes workloads and dev infrastructure. Confirm the environment, export necessary logs, check four archive checksums and snapshot completion, review the plan, then verify the dev state and residual billable inventory. Keep bootstrap, persistent and staging roots out of the dev destroy plan. Never use a broad bucket-empty, snapshot-delete or account-wide cleanup as a substitute for identifying ownership.
