# Dev teardown and recovery

Run these commands from the repository root on the Mac that holds your SSH key and initialized bootstrap/persistent Terraform directories. The workflow supports the established Mumbai dev deployment. It starts from the running environment and produces its first recovery checkpoint during teardown. A personal account needs its own bootstrap, persistent resources and initial deployment first.

## One-time workstation setup

1. Use Python 3.9+, Git, Terraform, AWS CLI, kubectl, Helm 4, Ansible, OpenSSH, curl and shasum. Install the MongoDB Atlas CLI if necessary (`brew install mongodb-atlas-cli` on Homebrew). Authenticate it for the capstone project with `atlas auth login` or configure a dedicated Atlas service account permitted to list, create and delete project IP access-list entries. See the [Atlas access-list commands](https://www.mongodb.com/docs/atlas/cli/current/command/atlas-accesslists-list/).
2. Obtain the Atlas **project ID**, Cloudflare **zone ID** and a Cloudflare API token with DNS edit access scoped to the application zone. The workflow reads, deletes and recreates the exact streaming application CNAME. The tunnel, Jenkins and SonarQube hostnames, Cloudflare Access policies and ACM validation records are retained. The [Cloudflare DNS API](https://developers.cloudflare.com/api/resources/dns/subresources/records/) documents the required access.
3. Authenticate the intended profile using `aws sso login --profile streamingapp` for organization SSO or `aws login --profile streamingapp` for the personal login-based profile. Run the two commands below. The configuration prompt hides the token and stores the settings outside Git. Environment variables override the saved values.

**Mac, repository root · local configuration and remote inspection.** Select the intended AWS profile/region and sign in to Atlas first. Expected result: a readable checkpoint configuration and a successful account/backend check.

```bash
python3 scripts/dev-session.py configure
python3 scripts/dev-session.py check
```

The check verifies the bootstrap account, initializes the existing dev backend, confirms Atlas and DNS read access, and lists releases for a running environment. It performs no cloud writes. An expired AWS or Atlas login needs renewal. Keep the SSH key, private checkpoint directory and encrypted workstation storage available across sessions. Cloud/AWS administrators need permission to snapshot/restore EBS volumes and read the EC2 console output as well as provision the stack.

## End a session

Finish active Jenkins builds and pause incoming changes. Use the same Git revision for teardown and the first restore. Record the branch/commit alongside your evidence. Run:

**Mac, repository root · Manual approval required.** Uses the saved session settings; success means verified backups and an empty dev state.

```bash
python3 scripts/dev-session.py down
```

Type `down-dev` when prompted. This confirmation starts backups and teardown. Allow the process to finish. The sequence is:

1. Capture the live Helm release versions and user values, five actual ECR image tags and digests, Grafana login, SMTP credentials, Alertmanager route, ingress hostname, DNS record and two NAT entries. A separate frontend release tag is preserved.
2. Take three encrypted-volume EBS snapshots for Grafana, Prometheus and Alertmanager and wait for completion. These are individual crash-consistent filesystem snapshots. Jenkins and SonarQube pause briefly while their archives and PostgreSQL logical dump are created. The script restarts the services and verifies SHA-256 checksums on the Mac before removing workloads.
3. Remove the app release and wait for the ALB to disappear. Remove monitoring and its captured claims, then wait for the associated EBS volumes to disappear. Remove the app CNAME and the two dev NAT entries from Atlas. The AWS controllers remain available during cleanup.
4. Plan and destroy the dev Terraform root. Success requires an empty dev state. The private `current` file points to the completed checkpoint.

The state bucket, ECR images, ACM certificate, private media, Secrets Manager application secret, Atlas database, SES identities, GitHub webhook configuration, and Cloudflare tunnel are retained. S3, snapshots and other persistent resources can continue to incur charges. Dev CloudWatch log groups managed by the dev root follow its destroy lifecycle. Export any log history required for compliance before teardown. Atlas database backup has its own lifecycle; this script snapshots monitoring storage and backs up CI data, not the Atlas database.

## Start the next session

Renew authentication if needed, then run:

**Mac, repository root · Manual approval required for provisioning and restore.** Use the same account, region and verified checkpoint. Expect recreated resources, healthy workloads and reachable endpoints.

```bash
python3 scripts/dev-session.py up
```

The runner checks the saved account and region, Jenkins/Sonar archive checksums, ECR digests and completed snapshots before provisioning. It derives the current admin /32, IAM role, AZs and retained resource ARNs. It reuses the previous Jenkins AMI (set `CAPSTONE_JENKINS_AMI` to a verified replacement if retired). For a non-SSO administrator identity set `CAPSTONE_EKS_ADMIN_ROLE_ARN` explicitly.

Terraform recreates dev. The runner adds the two new NAT addresses to Atlas, synchronizes application secrets, installs the load balancer controller and Cluster Autoscaler, restores the application and HPA, tests the ALB over HTTPS and recreates the CNAME. The host recovery playbook restores Jenkins, SonarQube, CloudWatch Agent, nginx and the tunnel connector. An existing trusted SSH key or an ED25519 key matching the authenticated EC2 boot console is required.

The runner restores three encrypted gp3 volumes from the snapshots in their original AZs. It reinstates Grafana credentials/dashboards, Prometheus history, Alertmanager state and the saved SES route. It replaces the Jenkins scrape address with the new private IP and restores Fluent Bit. The saved ingress attributes restore ALB log delivery. Finally it checks deployment rollouts and the public featured-video endpoint and refreshes the workstation kubeconfig.

## Checkpoints, interruptions and evidence

- `checkpoint` explicitly makes a backup without teardown. It pauses CI briefly and creates billable snapshots. Normal `down` already creates a fresh checkpoint, so this is optional.
- Default location: `~/PrivateBackups/capstone/dev-sessions/`. Use a dedicated private directory via `CAPSTONE_SESSION_DIR` if needed. The files contain recoverable SMTP, Grafana, database and Jenkins credentials. Keep the directory outside the repository on encrypted storage. Restrict access to it.
- If `down` fails before a verified checkpoint is published, inspect the timestamped directory and any snapshot IDs in `partial.json`. No workload cleanup is started at this stage. If cleanup or destroy stops after checkpoint publication, fix the reported error and rerun `down` to resume. Use `up` to retry an interrupted restore. Avoid running other Helm/Terraform updates concurrently.
- Keep the private directory, SSH key, immutable ECR image artifacts, AWS snapshots, Atlas project and provider credentials. ECR lifecycle policies and snapshot deletion can make an older checkpoint unusable. After a successful recovery, review old snapshot IDs in their manifests and apply your retention policy. The runner does not delete old recovery points.
- For acceptance, verify existing login/video playback, previous Jenkins job/Sonar analysis, a successful Jenkins build against the recreated cluster, Jenkins scrape value 1, one firing/resolved email pair, fresh logs and autoscaler node-group discovery. A separate controlled pending-pod test demonstrates actual node scaling.
- Reuse existing evidence. For the recovery drill save one final combined capture of empty dev state and one post-recovery capture showing the working release/pipeline. Routine installs, CLI output and repeated checks need no screenshots.

## Completion status

The manual dev workflow has demonstrated application deployment, CI, observability and recovery of Jenkins/SonarQube. The automatic full-cycle restore requires a live acceptance drill. Frontend image findings require rescanning the deployed digest and remediation where applicable. Automated Atlas backup and isolated restore validation, a healthy staging rollout, and production infrastructure and approval remain outstanding. Treat a move to another AWS account as a new deployment and data migration, not a restore of this account's checkpoint.

Review [retained resources and billing checks](dev-cost-and-scope.md) before ending a session. For the separate staging environment see [delivery](delivery.md).
