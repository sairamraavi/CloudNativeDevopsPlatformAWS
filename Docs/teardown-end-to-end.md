# Retire production, staging and development

Use this procedure when you plan to redeploy the project. It removes running environments and keeps the data needed for recovery. Run the commands on your setup workstation from the repository root with the same private configuration used for setup.

## 1. Prepare for downtime

Schedule downtime for all three environments. Pause Jenkins triggers, finish active builds and stop application writes. Confirm you can restore the Atlas databases and media you need. Keep your AWS, Cloudflare and Atlas sessions available and ensure the workstation can reach Jenkins and the clusters. Keep sufficient local disk space for the Jenkins backup. The teardown command needs these connections during cleanup.

## 2. Preview the Terraform changes

```bash
python3 scripts/platform.py teardown-plan "$HOME/.capstone-inputs/platform.json"
```

Review the AWS account, region and environment roots. The preview covers Terraform resources. Helm releases, traffic DNS, Atlas access-list entries, backups and monitoring volumes are handled separately by the live command. Preserve your private input files and the workstation's recovery metadata.

## 3. Run the teardown once

Replace ACCOUNT_ID with the personal AWS account number you verified. This authorizes downtime for all three environments.

```bash
python3 scripts/platform.py down "$HOME/.capstone-inputs/platform.json" --confirm-retire ACCOUNT_ID
```

The runner retires production, then staging, then development. For staging and production it checkpoints the monitoring volumes, removes the application and waits for its load balancer to disappear before retiring the cluster. Dev uses the existing checkpoint and retirement workflow for Jenkins and cluster resources. If cleanup fails, read the first error and fix the dependency before rerunning the command with the same private configuration and local metadata. A partially provisioned environment may require manual inspection. Preserve the private checkpoint directory printed at completion.

## 4. Verify and recover

Use the configured AWS profile and region to list EKS clusters, EC2 instances, NAT gateways, load balancers and EBS volumes. Compare identifiers against your environment inventory. Keep the state bucket, persistent Terraform roots, media buckets, registry images, secret versions, database backups and required snapshots for the next setup. Retained storage, external Atlas resources and other retained services can continue to incur charges.

Follow the [combined setup guide](setup-dev-stage-prod.md) to bring the environments back. Set jenkins_backup to the latest verified host backup before running up. Monitoring history from staging and production snapshots requires a separate volume restore if needed. Confirm application playback, Jenkins access and alert delivery after recovery. Keep backup archives outside Git because they contain private configuration and credentials.
