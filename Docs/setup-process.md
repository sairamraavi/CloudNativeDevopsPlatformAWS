# StreamingApp: step-by-step setup process

Repository: **https://github.com/sairamraavi/CloudNativeDevopsPlatformAWS**

Follow this guide in order. Each numbered step states where to run commands, what to configure, and what to verify before continuing. Commands assume Bash on a Mac unless a step says **Jenkins EC2**. Do not paste terminal prompts or Markdown link syntax into commands.

This guide describes the **development environment implemented in this repository**: Docker → Terraform → ECR → EKS → Atlas/S3 → HTTPS → monitoring → Jenkins/SonarQube → webhook deployment → logging → backup and teardown. Staging/production isolation, promotion approvals, automated database backup/restore, and a tested full recovery workflow remain separate work; they are not completed by this guide.

## Before starting

You need an AWS account with appropriate provisioning permissions, an AWS CLI SSO profile, Docker Desktop, Git, Terraform, kubectl, Helm, Ansible, Python 3, an Atlas account, and a domain managed in Cloudflare. SES email delivery and Cloudflare Tunnel are used later. AWS resources incur charges while running, including EKS, worker nodes, Jenkins, NAT gateways, load balancing, storage and logs.

The original implementation used Mumbai (`ap-south-1`), EKS 1.36, Terraform 1.15.8, Helm 4, Ubuntu 24.04 amd64 for Jenkins, and Node 24 container builds. These are recorded implementation versions, not a promise of current availability. Check regional EKS/add-on compatibility before provisioning. The checked-in Terraform pins are the source of truth.

Keep passwords, tunnel tokens, private keys and backup archives outside Git. Do not screenshot secret values. Run cloud commands only after checking the active AWS identity.

## Route through the guide

- **Steps 1–8:** prerequisites, local verification, persistent AWS resources, Atlas and images.
- **Steps 9–14:** EKS, secret synchronization, controllers and the public application.
- **Steps 15–18:** scaling, storage, dashboards and email alerts.
- **Steps 19–24:** Jenkins, SonarQube, webhook delivery and Jenkins metrics.
- **Steps 25–29:** logs, preservation, teardown and recreation.

## 1. Get the repository and confirm tools

**Mac:** clone only if you do not already have a checkout.

```bash
git clone https://github.com/sairamraavi/CloudNativeDevopsPlatformAWS.git
cd CloudNativeDevopsPlatformAWS
git switch develop
git status --short
```

Existing contributors can continue on their working branch; Jenkins must use the branch containing the committed changes.

```bash
git --version
docker version
docker compose version
terraform version
kubectl version --client
helm version --short
ansible --version
python3 --version
aws --version
```

Start Docker Desktop if the Docker server is unavailable. Install missing tools before proceeding. The Jenkinsfile uses Helm 4's `--rollback-on-failure` option.

**Expected:** all tools respond and you know which branch you are using.

## 2. Start an AWS session and choose your domain

Create an SSO profile if needed using `aws configure sso`; use your organization's supplied start URL and permission set. Then set your own values:

```bash
export AWS_PROFILE=streamingapp
export AWS_REGION=ap-south-1
export AWS_DEFAULT_REGION="$AWS_REGION"
export AWS_PAGER=''
export APP_DOMAIN=streaming.example.com
aws sso login --profile "$AWS_PROFILE"
aws sts get-caller-identity --query '{Account:Account,Arn:Arn}' --output json
```

Replace `streaming.example.com` with a subdomain you control. After confirming the displayed account is the intended account:

```bash
export CAPSTONE_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
export TF_VAR_expected_account_id="$CAPSTONE_ACCOUNT_ID"
export TF_VAR_aws_region="$AWS_REGION"
export TF_VAR_application_domain="$APP_DOMAIN"
export TF_VAR_media_allowed_origins="$(printf '["https://%s","http://localhost:3000"]' "$APP_DOMAIN")"
```

These exports apply only to this terminal. Repeat them in a new terminal. `ExpiredToken` means you need to log in again. Do not use Ctrl+Z to cancel Terraform: it suspends the process and can leave a state lock held. Use Ctrl+C and let Terraform exit.

## 3. Validate the application locally

**Mac, repository root:** copy the example only if `.env` does not exist.

```bash
test -f StreamingApp/.env || cp StreamingApp/.env.example StreamingApp/.env
git check-ignore StreamingApp/.env
openssl rand -hex 32 | tr -d '\n' | pbcopy
```

Paste the generated value into `JWT_SECRET` privately. Keep the local frontend URLs on ports 3000–3004 as shown in `.env.example`. Compose supplies the local MongoDB connection. AWS placeholder credentials are not usable credentials; local login can be verified first, and cloud media access is configured through workload IAM roles later.

```bash
docker compose -f StreamingApp/docker-compose.yml config --quiet
docker compose -f StreamingApp/docker-compose.yml up -d --build
docker compose -f StreamingApp/docker-compose.yml ps -a
curl -i --max-time 10 http://localhost:3001/health
curl -i --max-time 10 http://localhost:3002/api/health
curl -i --max-time 10 http://localhost:3003/api/health
curl -i --max-time 10 http://localhost:3004/api/health
docker compose -f StreamingApp/docker-compose.yml exec mongo mongosh --quiet --eval 'db.adminCommand({ ping: 1 })'
```

Open `http://localhost:3000`, register, log in and reload a nested route. Expected: health responses succeed, MongoDB returns `{ ok: 1 }`, and refresh does not return 404. Save evidence of the working application and health checks, not every command.

## 4. Create or reconnect Terraform remote state

There are three independent Terraform roots:

| Root | Purpose | Keep between development sessions? |
| --- | --- | --- |
| `Terraform/bootstrap` | State bucket and protection | Yes |
| `Terraform/persistent` | ECR, media, secret metadata, certificate, ALB log bucket | Yes |
| `Terraform/environments/dev` | EKS, networking, IAM, Jenkins and development infrastructure | Can be destroyed and recreated |

**Existing account with a configured backend:** run the following and keep the existing state bucket. Do not create a replacement or migrate to an empty backend.

```bash
terraform -chdir=Terraform/bootstrap init
terraform -chdir=Terraform/bootstrap plan -input=false
```

**First deployment in a new account only:** the state bucket must exist before using the S3 backend. Temporarily disable the backend declaration, create the bucket using local state, then migrate that state:

```bash
mv Terraform/bootstrap/backend.tf Terraform/bootstrap/backend.tf.disabled
terraform -chdir=Terraform/bootstrap init
terraform -chdir=Terraform/bootstrap validate
terraform -chdir=Terraform/bootstrap plan -input=false -out=bootstrap.tfplan
terraform -chdir=Terraform/bootstrap apply bootstrap.tfplan
export CAPSTONE_STATE_BUCKET="$(terraform -chdir=Terraform/bootstrap output -raw terraform_state_bucket_name)"
mv Terraform/bootstrap/backend.tf.disabled Terraform/bootstrap/backend.tf
terraform -chdir=Terraform/bootstrap init -migrate-state \
  -backend-config="bucket=$CAPSTONE_STATE_BUCKET" \
  -backend-config="key=bootstrap/terraform.tfstate" \
  -backend-config="region=$AWS_REGION" \
  -backend-config="encrypt=true" \
  -backend-config="use_lockfile=true"
```

Answer `yes` to copy the existing local state. Keep any local state backups private. Never commit state or saved plans.

**Both paths:**

```bash
export CAPSTONE_STATE_BUCKET="$(terraform -chdir=Terraform/bootstrap output -raw terraform_state_bucket_name)"
terraform -chdir=Terraform/bootstrap state list
terraform -chdir=Terraform/bootstrap plan -input=false
```

Expected: protected state-bucket resources exist and the follow-up plan reports no changes. Save one screenshot of remote-state verification.

## 5. Provision persistent resources

```bash
terraform -chdir=Terraform/persistent init \
  -backend-config="bucket=$CAPSTONE_STATE_BUCKET" \
  -backend-config="key=persistent/terraform.tfstate" \
  -backend-config="region=$AWS_REGION" \
  -backend-config="encrypt=true" \
  -backend-config="use_lockfile=true"
terraform -chdir=Terraform/persistent validate
terraform -chdir=Terraform/persistent plan -input=false -out=persistent.tfplan
```

Review the plan, especially account, region, domain and CORS origins. Apply only the intended resources:

```bash
terraform -chdir=Terraform/persistent apply persistent.tfplan
terraform -chdir=Terraform/persistent output
export CAPSTONE_MEDIA_BUCKET="$(terraform -chdir=Terraform/persistent output -raw media_bucket_name)"
export TF_VAR_media_bucket_arn="$(terraform -chdir=Terraform/persistent output -raw media_bucket_arn)"
export TF_VAR_application_secret_arn="$(terraform -chdir=Terraform/persistent output -raw application_dev_secret_arn)"
export CAPSTONE_CERT_ARN="$(terraform -chdir=Terraform/persistent output -raw application_certificate_arn)"
export CAPSTONE_ALB_LOG_BUCKET="$(terraform -chdir=Terraform/persistent output -raw alb_logs_bucket_name)"
```

Expected: five ECR repositories, private media bucket, secret container, ACM certificate request and ALB access-log bucket. The secret container does **not** yet contain application credentials.

## 6. Validate the HTTPS certificate in Cloudflare

```bash
terraform -chdir=Terraform/persistent output application_certificate_dns_records
```

In Cloudflare DNS, add each returned CNAME exactly as provided. Set validation records to **DNS only**. Leave these records in place for certificate renewal.

```bash
aws acm describe-certificate --region "$AWS_REGION" \
  --certificate-arn "$CAPSTONE_CERT_ARN" \
  --query 'Certificate.{Domain:DomainName,Status:Status}' --output json
```

Continue when status is `ISSUED`. Capture the certificate status; this is separate from the application DNS CNAME added after the ALB exists.

## 7. Create Atlas and populate application secrets

1. Create an Atlas project and cluster in the intended region. The original development setup used the free tier, which had no managed backups enabled; this is a development compromise.
2. Create a database user with `readWrite` access to the `streamingapp` database. Store its password privately.
3. Add your current Mac public IPv4 as a `/32` Atlas IP access entry for testing. Do not open access to all addresses.
4. Copy your cluster's SRV hostname from Atlas Connect. Use the password prompt, not a password in shell history:

```bash
export ATLAS_HOST='replace-with-your-cluster.mongodb.net'
docker run --rm -it mongo:8.0 mongosh \
  "mongodb+srv://${ATLAS_HOST}/streamingapp?retryWrites=true&w=majority&authSource=admin" \
  --username streamingapp-dev --password
```

Inside mongosh:

```javascript
db.runCommand({ ping: 1 })
db.getName()
const verificationId = new ObjectId();
db.capstone_connection_checks.insertOne({ _id: verificationId, purpose: 'connectivity-check', checkedAt: new Date() });
db.capstone_connection_checks.findOne({ _id: verificationId });
db.capstone_connection_checks.deleteOne({ _id: verificationId });
exit
```

In AWS Secrets Manager, open `streamingapp-capstone/dev/application` and store two key/value pairs: `MONGO_URI` (complete Atlas URI with URL-encoded credentials and database name) and `JWT_SECRET` (generated random secret). Generate the JWT secret using the clipboard command in step 3. It is a signing secret, not a login token.

```bash
aws secretsmanager list-secret-version-ids \
  --secret-id "$TF_VAR_application_secret_arn" \
  --query 'Versions[].{Version:VersionId,Stages:VersionStages}' --output table
```

Expected: a version marked `AWSCURRENT`. Screenshot version metadata only. Do not print secret contents.

## 8. Build and publish the first cloud images

The first deployment needs images before Jenkins exists. Use the correct Docker build contexts below. Cloud frontend API URLs are build-time settings; changing a Kubernetes environment variable does not rebuild JavaScript.

```bash
export ECR_REGISTRY="${CAPSTONE_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
export IMAGE_TAG="$(git rev-parse --short=12 HEAD)-$(date -u +%Y%m%d%H%M%S)"
aws ecr get-login-password --region "$AWS_REGION" |
  docker login --username AWS --password-stdin "$ECR_REGISTRY"
docker build --pull --platform linux/amd64 \
  -t "$ECR_REGISTRY/streamingapp-capstone-auth:$IMAGE_TAG" \
  StreamingApp/backend/authService
for service in streaming admin chat; do
  docker build --pull --platform linux/amd64 \
    -f "StreamingApp/backend/${service}Service/Dockerfile" \
    -t "$ECR_REGISTRY/streamingapp-capstone-$service:$IMAGE_TAG" \
    StreamingApp/backend || break
done
docker build --pull --platform linux/amd64 \
  --build-arg REACT_APP_AUTH_API_URL=/api \
  --build-arg REACT_APP_STREAMING_API_URL=/api \
  --build-arg REACT_APP_STREAMING_PUBLIC_URL="https://$APP_DOMAIN" \
  --build-arg REACT_APP_ADMIN_API_URL=/api/admin \
  --build-arg REACT_APP_CHAT_API_URL=/api/chat \
  --build-arg REACT_APP_CHAT_SOCKET_URL="https://$APP_DOMAIN" \
  -t "$ECR_REGISTRY/streamingapp-capstone-frontend:$IMAGE_TAG" StreamingApp/frontend
docker run --rm --platform linux/amd64 \
  "$ECR_REGISTRY/streamingapp-capstone-frontend:$IMAGE_TAG" nginx -t
for service in auth streaming admin chat frontend; do
  docker push "$ECR_REGISTRY/streamingapp-capstone-$service:$IMAGE_TAG" || break
done
```

Stop if any build/push fails. Record the image tag. **Do not use `/api/streaming` for `REACT_APP_STREAMING_API_URL`**: the client already appends `/streaming`, causing duplicate paths and 404 responses.

Inspect each image and query scans using the `linux/amd64` child digest when its tag points to an OCI image index:

```bash
docker buildx imagetools inspect "$ECR_REGISTRY/streamingapp-capstone-frontend:$IMAGE_TAG"
```

Copy the actual amd64 digest into the next command, replacing the placeholder:

```bash
aws ecr describe-image-scan-findings \
  --repository-name streamingapp-capstone-frontend \
  --image-id imageDigest=REPLACE_WITH_ACTUAL_SHA256_DIGEST \
  --query '{Status:imageScanStatus.status,Counts:imageScanFindings.findingSeverityCounts}'
```

Repeat for all five services. A completed scan with empty counts means no findings reported by that scan, not proof of complete security. The historical frontend release had unresolved findings; do not label it production-approved. Capture the scan summary and any remediation evidence.

## 9. Supply development infrastructure inputs

Create the Jenkins SSH key only if it is absent. Never overwrite an existing key needed for recovery.

```bash
test -s "$HOME/.ssh/streamingapp-capstone-jenkins" || \
  ssh-keygen -t ed25519 -f "$HOME/.ssh/streamingapp-capstone-jenkins" -C streamingapp-capstone-jenkins
export CAPSTONE_ADMIN_IP="$(curl -4 --fail --silent --show-error https://checkip.amazonaws.com)"
export TF_VAR_eks_public_access_cidrs="$(printf '["%s/32"]' "$CAPSTONE_ADMIN_IP")"
export TF_VAR_jenkins_admin_cidr="${CAPSTONE_ADMIN_IP}/32"
export TF_VAR_jenkins_public_key_path="$HOME/.ssh/streamingapp-capstone-jenkins.pub"
export TF_VAR_availability_zones='["ap-south-1a","ap-south-1b"]'
export TF_VAR_nat_mode=per_az
```

In IAM, locate the **IAM role ARN** of your SSO administrator role (not the STS assumed-role session ARN). In EC2, select a verified Canonical Ubuntu 24.04 amd64 AMI in your region. Set both values:

```bash
export TF_VAR_eks_admin_role_arn='REPLACE_WITH_YOUR_IAM_ROLE_ARN'
export TF_VAR_jenkins_ami_id='REPLACE_WITH_VERIFIED_REGIONAL_UBUNTU_AMI_ID'
```

These placeholders must be replaced before planning. The checked-in EKS configuration requires `per_az` NAT for its private-node design. Choose different AZs only after updating the configuration consistently.

## 10. Create EKS, networking and Jenkins EC2

```bash
terraform -chdir=Terraform/environments/dev init \
  -backend-config="bucket=$CAPSTONE_STATE_BUCKET" \
  -backend-config="key=environments/dev/terraform.tfstate" \
  -backend-config="region=$AWS_REGION" \
  -backend-config="encrypt=true" \
  -backend-config="use_lockfile=true"
terraform -chdir=Terraform/environments/dev validate
terraform -chdir=Terraform/environments/dev plan -input=false -out=dev.tfplan
```

Review all changes. On recreation, outputs such as public IPs, NAT IPs, VPC IDs and endpoints will change. Save the reviewed plan screenshot, then:

```bash
terraform -chdir=Terraform/environments/dev apply dev.tfplan
export CAPSTONE_CLUSTER_NAME="$(terraform -chdir=Terraform/environments/dev output -raw eks_cluster_name)"
export CAPSTONE_VPC_ID="$(terraform -chdir=Terraform/environments/dev output -raw vpc_id)"
export CAPSTONE_JENKINS_IP="$(terraform -chdir=Terraform/environments/dev output -raw jenkins_public_ip)"
aws eks update-kubeconfig --region "$AWS_REGION" --name "$CAPSTONE_CLUSTER_NAME" --alias streamingapp-capstone-dev
kubectl --context streamingapp-capstone-dev auth can-i list nodes
kubectl --context streamingapp-capstone-dev get nodes -L topology.kubernetes.io/zone
kubectl --context streamingapp-capstone-dev get pods -n kube-system
terraform -chdir=Terraform/environments/dev output nat_public_ips
```

Expected: two Ready nodes across two AZs and healthy system pods. Add **both new NAT IPs as `/32` entries in Atlas**; remove obsolete NAT entries after replacement. Capture cluster readiness and Atlas access-list evidence.

## 11. Install External Secrets and synchronize application credentials

```bash
kubectl --context streamingapp-capstone-dev create namespace streaming-app-dev --dry-run=client -o yaml |
  kubectl --context streamingapp-capstone-dev apply -f -
helm repo add external-secrets https://charts.external-secrets.io
helm repo update external-secrets
helm search repo external-secrets/external-secrets --versions | head
```

Select a compatible chart version and replace the placeholder below. The session's repository listing included 2.14.0; verify availability before using it.

```bash
export ESO_CHART_VERSION='REPLACE_WITH_SELECTED_VERSION'
helm upgrade --install external-secrets external-secrets/external-secrets \
  --version "$ESO_CHART_VERSION" --kube-context streamingapp-capstone-dev \
  -n external-secrets --create-namespace --set installCRDs=true --wait --timeout 5m
export SECRET_READER_ROLE_ARN="$(terraform -chdir=Terraform/environments/dev output -raw secret_reader_role_arn)"
helm upgrade --install application-secrets helm/application-secrets \
  --kube-context streamingapp-capstone-dev -n streaming-app-dev \
  --set-string secretReader.roleArn="$SECRET_READER_ROLE_ARN" \
  --set-string awsRegion="$AWS_REGION"
kubectl --context streamingapp-capstone-dev get secretstore,externalsecret -n streaming-app-dev
kubectl --context streamingapp-capstone-dev wait --for=condition=Ready \
  externalsecret/streamingapp-application -n streaming-app-dev --timeout=180s
```

Continue only after synchronization succeeds. Save readiness evidence without decoding the Kubernetes Secret.

## 12. Install the AWS Load Balancer Controller

```bash
helm repo add eks https://aws.github.io/eks-charts
helm repo update eks
export CAPSTONE_LBC_ROLE_ARN="$(terraform -chdir=Terraform/environments/dev output -raw load_balancer_controller_role_arn)"
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --version 1.14.1 --kube-context streamingapp-capstone-dev -n kube-system \
  --set-string clusterName="$CAPSTONE_CLUSTER_NAME" \
  --set-string region="$AWS_REGION" --set-string vpcId="$CAPSTONE_VPC_ID" \
  --set serviceAccount.create=true --set-string serviceAccount.name=aws-load-balancer-controller \
  --set-string "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=$CAPSTONE_LBC_ROLE_ARN" \
  --set replicaCount=2 --wait --timeout 5m
kubectl --context streamingapp-capstone-dev get deployment aws-load-balancer-controller -n kube-system
kubectl --context streamingapp-capstone-dev get ingressclass alb
```

Expected: controller 2/2 Ready and ingress class `alb`. The chart version matches the checked-in v2.14.1 IAM policy.

## 13. Install the application with this deployment's values

```bash
export CAPSTONE_ADMIN_MEDIA_ROLE="$(terraform -chdir=Terraform/environments/dev output -json media_workload_role_arns | python3 -c 'import json,sys; print(json.load(sys.stdin)["admin"])')"
export CAPSTONE_STREAMING_MEDIA_ROLE="$(terraform -chdir=Terraform/environments/dev output -json media_workload_role_arns | python3 -c 'import json,sys; print(json.load(sys.stdin)["streaming"])')"
helm lint helm/streamingapp
helm upgrade --install streamingapp helm/streamingapp \
  --kube-context streamingapp-capstone-dev -n streaming-app-dev \
  --set-string image.registry="$ECR_REGISTRY" --set-string image.tag="$IMAGE_TAG" \
  --set-string frontend.tag="$IMAGE_TAG" \
  --set-string app.clientUrls="https://$APP_DOMAIN" \
  --set-string app.streamingPublicUrl="https://$APP_DOMAIN" \
  --set-string app.awsRegion="$AWS_REGION" --set-string app.s3Bucket="$CAPSTONE_MEDIA_BUCKET" \
  --set-string services.admin.roleArn="$CAPSTONE_ADMIN_MEDIA_ROLE" \
  --set-string services.streaming.roleArn="$CAPSTONE_STREAMING_MEDIA_ROLE" \
  --set ingress.enabled=true --set-string ingress.host="$APP_DOMAIN" \
  --set-string ingress.certificateArn="$CAPSTONE_CERT_ARN" \
  --wait --timeout 10m
kubectl --context streamingapp-capstone-dev get deployments,pods,ingress -n streaming-app-dev
```

Expected: all five deployments ready and an ALB hostname appears on the ingress. If pods fail, inspect their events/logs before proceeding; common causes are Atlas NAT entries, secret synchronization or incorrect image registry/tag.

## 14. Point DNS at the ALB and test the public application

```bash
kubectl --context streamingapp-capstone-dev get ingress streamingapp -n streaming-app-dev \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{"\n"}'
```

Create your application's Cloudflare CNAME pointing to that hostname, **DNS only** for the initial ACM/ALB validation. Do not replace the certificate validation CNAME.

```bash
dig +short CNAME "$APP_DOMAIN"
curl --silent --show-error --max-time 20 -o /dev/null -D - "http://$APP_DOMAIN/"
curl --silent --show-error --max-time 20 -o /dev/null -D - "https://$APP_DOMAIN/"
```

Expected: HTTP redirects to HTTPS; HTTPS returns 200. Register/login, refresh `/browse`, upload and play a small video using an authorized admin, and test chat with two users. Confirm normal users cannot access admin APIs. Do not promote arbitrary users to admin without reviewing the application's authorization implementation.

Capture only major proof: HTTPS, login/API routing, S3 upload, playback, two-user chat and admin rejection. API requests should use your public domain, not localhost.

## 15. Verify scaling and persistent-storage prerequisites

The current Terraform root includes metrics-server and EBS CSI resources; do not install duplicate copies manually.

```bash
kubectl --context streamingapp-capstone-dev top nodes
kubectl --context streamingapp-capstone-dev top pods -n streaming-app-dev
kubectl --context streamingapp-capstone-dev get hpa -n streaming-app-dev
kubectl --context streamingapp-capstone-dev get csidriver ebs.csi.aws.com
kubectl --context streamingapp-capstone-dev apply -f Monitoring/storage/gp3-encrypted.yaml
kubectl --context streamingapp-capstone-dev get storageclass capstone-gp3-encrypted
```

To reproduce the bounded frontend HPA test:

```bash
kubectl --context streamingapp-capstone-dev apply -f tests/frontend-hpa-load.yaml
kubectl --context streamingapp-capstone-dev get hpa frontend -n streaming-app-dev --watch
```

Ctrl+C ends the watch. After collecting scale-up evidence:

```bash
kubectl --context streamingapp-capstone-dev logs job/frontend-hpa-load -n streaming-app-dev
kubectl --context streamingapp-capstone-dev delete job frontend-hpa-load -n streaming-app-dev --ignore-not-found
kubectl --context streamingapp-capstone-dev get hpa frontend -n streaming-app-dev
```

Allow the configured five-minute downscale stabilization period. Capture scale-down once it returns to one replica. HPA scales pods; Cluster Autoscaler scales worker nodes.

## 16. Install Cluster Autoscaler

```bash
export CAPSTONE_AUTOSCALER_ROLE="$(terraform -chdir=Terraform/environments/dev output -raw autoscaler_role_arn)"
helm repo add autoscaler https://kubernetes.github.io/autoscaler
helm repo update autoscaler
helm upgrade --install cluster-autoscaler autoscaler/cluster-autoscaler \
  --version 9.59.0 --kube-context streamingapp-capstone-dev -n kube-system \
  -f Monitoring/cluster-autoscaler-values.yaml \
  --set-string awsRegion="$AWS_REGION" --set-string autoDiscovery.clusterName="$CAPSTONE_CLUSTER_NAME" \
  --set-string "rbac.serviceAccount.annotations.eks\.amazonaws\.com/role-arn=$CAPSTONE_AUTOSCALER_ROLE" \
  --set-string 'rbac.serviceAccount.annotations.eks\.amazonaws\.com/sts-regional-endpoints=true' \
  --wait --timeout 5m
kubectl --context streamingapp-capstone-dev logs deployment/cluster-autoscaler -n kube-system --tail=50
```

The values pin the autoscaler image to Kubernetes minor 1.36; do not rely on the chart's default app version. Annotations must render as YAML strings. Verify discovery and absence of access-denied errors before claiming autoscaling is operational.

## 17. Prepare monitoring passwords and install Prometheus/Grafana

Create the namespace, then create the Grafana admin Secret using a temporary private directory. These commands do not print the password:

```bash
kubectl --context streamingapp-capstone-dev create namespace monitoring --dry-run=client -o yaml |
  kubectl --context streamingapp-capstone-dev apply -f -
CAPSTONE_SECRET_DIR="$(mktemp -d)"
chmod 700 "$CAPSTONE_SECRET_DIR"
printf admin > "$CAPSTONE_SECRET_DIR/admin-user"
read -r -s -p 'Choose Grafana password: ' CAPSTONE_GRAFANA_PASSWORD
printf '\n'
printf '%s' "$CAPSTONE_GRAFANA_PASSWORD" > "$CAPSTONE_SECRET_DIR/admin-password"
chmod 600 "$CAPSTONE_SECRET_DIR/"*
kubectl --context streamingapp-capstone-dev create secret generic grafana-admin -n monitoring \
  --from-file=admin-user="$CAPSTONE_SECRET_DIR/admin-user" \
  --from-file=admin-password="$CAPSTONE_SECRET_DIR/admin-password" \
  --dry-run=client -o yaml | kubectl --context streamingapp-capstone-dev apply -f -
unset CAPSTONE_GRAFANA_PASSWORD
rm -r "$CAPSTONE_SECRET_DIR"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update prometheus-community
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  --version 92.16.1 --kube-context streamingapp-capstone-dev -n monitoring \
  -f Monitoring/kube-prometheus-stack-values.yaml \
  --set 'alertmanager.alertmanagerSpec.alertmanagerConfiguration=null' \
  --set 'prometheus.prometheusSpec.additionalScrapeConfigs=[]' \
  --wait --timeout 10m
kubectl --context streamingapp-capstone-dev get pods,pvc -n monitoring
```

The two initial overrides avoid referencing an email configuration that is not created yet or an old Jenkins private IP. Configure them in later steps. Expected: running pods and three Bound PVCs.

Open separate Mac terminals and keep each port-forward running:

```bash
kubectl --context streamingapp-capstone-dev port-forward -n monitoring service/monitoring-grafana 3000:80
```

```bash
kubectl --context streamingapp-capstone-dev port-forward -n monitoring service/monitoring-kube-prometheus-prometheus 9090:9090
```

Use `http://localhost:3000` for Grafana (choose 3005:80 if the local app uses 3000) and `http://localhost:9090` for Prometheus. Log in with the Grafana password just chosen. Open Kubernetes cluster/namespace resource dashboards. In Prometheus, run `up` and `up == 0`; inspect Targets. Save dashboard and target-health screenshots. Metrics-server is not a replacement for Prometheus historical monitoring.

## 18. Configure email alerts through SES

1. In SES in the same region, verify a sender domain using its DNS records and verify your recipient email if the account remains in the sandbox.
2. Create SES SMTP credentials and restrict their sending permissions. These are **SMTP credentials**, not your Outlook password.
3. Edit `Monitoring/alertmanager-email.yaml`: use your recipient, verified sender and regional SMTP hostname. Leave the `__SES_SMTP_USERNAME__` marker until rendering. `authUsername` is a string; `authPassword` is a Secret reference.
4. Create `monitoring/alertmanager-ses-smtp` with `username` and `password` keys privately. Use the temporary-file pattern from step 17, substituting these two filenames and Secret name. Do not commit the values.
Use this command sequence for step 4:

```bash
CAPSTONE_SMTP_DIR="$(mktemp -d)"
chmod 700 "$CAPSTONE_SMTP_DIR"
read -r -s -p 'SES SMTP username: ' CAPSTONE_SMTP_USERNAME
printf '\n'
read -r -s -p 'SES SMTP password: ' CAPSTONE_SMTP_PASSWORD
printf '\n'
printf '%s' "$CAPSTONE_SMTP_USERNAME" > "$CAPSTONE_SMTP_DIR/username"
printf '%s' "$CAPSTONE_SMTP_PASSWORD" > "$CAPSTONE_SMTP_DIR/password"
chmod 600 "$CAPSTONE_SMTP_DIR/"*
kubectl --context streamingapp-capstone-dev create secret generic alertmanager-ses-smtp -n monitoring \
  --from-file=username="$CAPSTONE_SMTP_DIR/username" --from-file=password="$CAPSTONE_SMTP_DIR/password" \
  --dry-run=client -o yaml | kubectl --context streamingapp-capstone-dev apply -f -
unset CAPSTONE_SMTP_USERNAME CAPSTONE_SMTP_PASSWORD
rm -r "$CAPSTONE_SMTP_DIR"
```

5. Render the username from the Secret into the configuration and apply it without displaying credentials:

```bash
python3 - <<'PYSES'
import base64, json, pathlib, subprocess
base = ['kubectl', '--context', 'streamingapp-capstone-dev']
s = json.loads(subprocess.check_output(base + ['get', 'secret', 'alertmanager-ses-smtp', '-n', 'monitoring', '-o', 'json']))
u = base64.b64decode(s['data']['username']).decode()
text = pathlib.Path('Monitoring/alertmanager-email.yaml').read_text()
text = text.replace('"__SES_SMTP_USERNAME__"', json.dumps(u))
subprocess.run(base + ['apply', '-f', '-'], input=text, text=True, check=True)
PYSES
helm upgrade monitoring prometheus-community/kube-prometheus-stack \
  --version 92.16.1 --kube-context streamingapp-capstone-dev -n monitoring \
  --reuse-values --set-string alertmanager.alertmanagerSpec.alertmanagerConfiguration.name=capstone-email \
  --wait --timeout 10m
kubectl --context streamingapp-capstone-dev apply -f tests/monitoring-email-alert.yaml
```

Wait for the test alert to fire and arrive in the inbox. Confirm delivery rather than just a firing rule. Then remove the synthetic rule:

```bash
kubectl --context streamingapp-capstone-dev delete -f tests/monitoring-email-alert.yaml
```

Capture firing and resolved emails. SES usage is billable subject to account allowances; do not assume it is free.

## 19. Configure the Jenkins host through Ansible

**Mac, repository root:** refresh the current EC2 IP rather than reusing an earlier session's address.

```bash
export CAPSTONE_JENKINS_IP="$(terraform -chdir=Terraform/environments/dev output -raw jenkins_public_ip)"
ssh -i "$HOME/.ssh/streamingapp-capstone-jenkins" "ubuntu@$CAPSTONE_JENKINS_IP"
```

Confirm the host fingerprint using trusted EC2 information before accepting a new key. Exit back to the Mac. Customize `Ansible/roles/nginx/defaults/main.yml` for your Jenkins and SonarQube hostnames. Review version pins in `Ansible/group_vars/all/main.yml`.

```bash
cd Ansible
ansible jenkins -m ansible.builtin.ping
ansible-playbook playbooks/jenkins.yml -e @group_vars/all/main.yml --syntax-check
ansible-playbook playbooks/jenkins.yml -e @group_vars/all/main.yml --skip-tags cloudflared
ansible jenkins -b --become-user=jenkins -m ansible.builtin.command -a 'docker ps'
ansible jenkins -b --become-user=jenkins -m ansible.builtin.command -a 'aws sts get-caller-identity --region ap-south-1'
cd ..
```

Cloudflared is deliberately deferred until a valid private token exists. Confirm the AWS identity is the Jenkins instance role. The host should not use copied SSO/static AWS credentials.

Open Jenkins through an SSH tunnel **from the Mac**, not inside EC2:

```bash
ssh -i "$HOME/.ssh/streamingapp-capstone-jenkins" -N \
  -L 18080:127.0.0.1:8080 -L 19000:127.0.0.1:9000 "ubuntu@$CAPSTONE_JENKINS_IP"
```

Visit `http://127.0.0.1:18080`. For a fresh installation, obtain the initial admin password privately on EC2 using `sudo cat /var/lib/jenkins/secrets/initialAdminPassword`, finish the wizard and create an administrator. Never screenshot that password.

## 20. Give Jenkins its Kubernetes context

```bash
cd Ansible
ansible jenkins -b --become-user=jenkins -m ansible.builtin.command \
  -a 'aws eks update-kubeconfig --region ap-south-1 --name streamingapp-capstone-dev-eks --alias streamingapp-capstone-dev --kubeconfig /var/lib/jenkins/.kube/config'
ansible jenkins -b --become-user=jenkins -m ansible.builtin.command \
  -a 'kubectl --kubeconfig /var/lib/jenkins/.kube/config --context streamingapp-capstone-dev auth can-i patch deployments -n streaming-app-dev'
ansible jenkins -b --become-user=jenkins -m ansible.builtin.command \
  -a 'kubectl --kubeconfig /var/lib/jenkins/.kube/config --context streamingapp-capstone-dev auth can-i delete nodes'
cd ..
```

Expected: namespace deployment check says `yes`; node deletion says `no` (Ansible reports a nonzero result for this intentional negative test). The Terraform access policy and security-group rule must exist first. Capture this scoped-access proof.

## 21. Start SonarQube and configure the quality gate

Copy `Monitoring/sonarqube/compose.yaml` to `/opt/capstone-sonarqube/compose.yaml` on Jenkins EC2. Create a private `.env` there containing `POSTGRES_IMAGE`, `SONAR_IMAGE` and a strong `SONAR_DB_PASSWORD`. Use compatible, verified image versions/digests, not arbitrary latest tags. Preserve the same database major version when restoring an existing dump.

**Mac, repository root:** transfer the checked-in Compose file:

```bash
scp -i "$HOME/.ssh/streamingapp-capstone-jenkins" Monitoring/sonarqube/compose.yaml "ubuntu@$CAPSTONE_JENKINS_IP:/tmp/capstone-sonarqube-compose.yaml"
```

**Jenkins EC2:** create the directory and install the file:

```bash
sudo install -d -m 750 /opt/capstone-sonarqube
sudo install -m 640 /tmp/capstone-sonarqube-compose.yaml /opt/capstone-sonarqube/compose.yaml
sudo install -m 600 /dev/null /opt/capstone-sonarqube/.env
sudo nano /opt/capstone-sonarqube/.env
```

Use the following format in the editor. Replace the placeholders with the selected image references and a password; do not run this as shell code. The `install /dev/null` command is for a **fresh installation only** and would erase an existing `.env`.

```dotenv
POSTGRES_IMAGE=postgres@sha256:YOUR_VERIFIED_COMPATIBLE_DIGEST
SONAR_IMAGE=sonarqube@sha256:YOUR_VERIFIED_COMPATIBLE_DIGEST
SONAR_DB_PASSWORD=YOUR_PRIVATE_RANDOM_PASSWORD
```

**Jenkins EC2:**

```bash
sudo chmod 600 /opt/capstone-sonarqube/.env
sudo sysctl -w vm.max_map_count=1048576
printf 'vm.max_map_count=1048576\n' | sudo tee /etc/sysctl.d/99-sonarqube.conf
sudo docker compose --project-directory /opt/capstone-sonarqube \
  --env-file /opt/capstone-sonarqube/.env -f /opt/capstone-sonarqube/compose.yaml up -d
curl --fail --silent --show-error http://127.0.0.1:9000/api/system/status
```

Wait for `UP`; a connection reset during startup is not itself proof of permanent failure. Use Compose logs if it does not become ready. The original compose limits require sufficient host memory.

Open `http://127.0.0.1:19000` through the Mac tunnel. Change the initial password, create project key `streamingapp-capstone` (matching `sonar-project.properties`), generate a project analysis token, and store it as a Jenkins Secret Text credential. In Jenkins install/configure the SonarQube Scanner integration:

- Server configuration name: `capstone-sonarqube`; URL from Jenkins: `http://127.0.0.1:9000`.
- Scanner tool name: `capstone-sonar-scanner`.
- Bind the token credential to the SonarQube server configuration.

The current project properties make the scanner wait for its quality gate. A restored SonarQube instance already containing the project does not need a duplicate project.

## 22. Configure and run the Jenkins pipeline

The Jenkinsfile compares the instance-role account against the configured dev cluster ARN, derives the ECR registry from the account and region, and reads the application hostname from the deployed Ingress. The job expects the dev cluster and namespace names used by this guide.

Install the Pipeline, Git, GitHub, SonarQube Scanner and Prometheus metrics plugins as required by the Jenkinsfile and monitoring. Create a Pipeline job:

1. Name: `streamingapp-dev`.
2. Definition: **Pipeline script from SCM**, SCM: Git.
3. Repository: your repository URL; use a read credential if private.
4. Branch specifier: the branch containing the Jenkinsfile, e.g. `*/develop` or `*/feature/capstone-end-to-end`.
5. Script path: `Jenkinsfile`.
6. Save and choose **Build Now**.

The first manual application installation in step 13 is required: the current pipeline uses `helm upgrade`, not first-install provisioning. Expected sequence: checkout → tests → SonarQube gate → tool/identity/access checks → build → ECR push → Helm upgrade → rollout/HTTPS checks. Save a successful full pipeline screenshot and quality-gate evidence. Do not treat only the initial verification stages as a completed deployment pipeline.

## 23. Configure Cloudflare Tunnel and the GitHub webhook

Create a Cloudflare Tunnel for this Jenkins host. Store its connector token privately at `/etc/cloudflared/token`, owned by root with mode 600. Do not paste token values into Git, screenshots, or chat. The role can alternatively receive `vault_cloudflared_tunnel_token` from an encrypted Ansible Vault file.

In Cloudflare configure public hostnames:

| Hostname | Origin on EC2 |
| --- | --- |
| Your Jenkins hostname | `http://127.0.0.1:8081` |
| Your SonarQube hostname | `http://127.0.0.1:8082` |

The two nginx listeners are loopback-only. Jenkins metrics use the **private EC2 IP** on port 8082; this is a different listening address from SonarQube's loopback port.

**Mac:**

```bash
cd Ansible
ansible-playbook playbooks/jenkins.yml -e @group_vars/all/main.yml --tags cloudflared
cd ..
```

Verify the tunnel is healthy and both URLs load. Restrict dashboard access through Cloudflare Access and application authorization. Configure the exact `/github-webhook/` path so GitHub can reach it without an interactive Access login; retain POST-only handling and configure webhook secret verification in Jenkins/GitHub. Do not bypass access control for the entire hostname.

In GitHub repository Settings → Webhooks add `https://YOUR_JENKINS_HOST/github-webhook/`, JSON content type, SSL verification enabled and push events. Confirm delivery succeeds, then push an intended commit and verify an automatic successful build. Save webhook delivery and automatically triggered build evidence.

## 24. Connect Jenkins metrics to Prometheus

Verify the Prometheus plugin endpoint on **Jenkins EC2**:

```bash
curl --fail --silent --show-error http://127.0.0.1:8080/prometheus/ | head
sudo nginx -t
```

Get the current private address from Terraform on the Mac:

```bash
terraform -chdir=Terraform/environments/dev output -raw jenkins_private_ip
```

Replace the old Jenkins target in `Monitoring/kube-prometheus-stack-values.yaml` with this private IP plus `:8082`. Ensure the Terraform security-group rule permits the intended monitoring source. Reapply the complete values file now that `capstone-email` exists:

```bash
helm upgrade monitoring prometheus-community/kube-prometheus-stack \
  --version 92.16.1 --kube-context streamingapp-capstone-dev -n monitoring \
  -f Monitoring/kube-prometheus-stack-values.yaml --wait --timeout 10m
```

Query `up{job="jenkins"}` in Prometheus; expected value is 1. Import `Monitoring/dashboards/jenkins-monitoring.json` into Grafana and select the Prometheus data source. Capture a populated dashboard, not an empty one.

## 25. Verify CloudWatch application and Jenkins logs

Terraform creates log groups and IAM access. Ansible installs/configures the Jenkins CloudWatch agent. For application logs, install Fluent Bit with the role from this deployment:

```bash
export CAPSTONE_LOG_ROLE="$(terraform -chdir=Terraform/environments/dev output -raw application_logs_role_arn)"
helm repo add fluent https://fluent.github.io/helm-charts
helm repo update fluent
helm search repo fluent/fluent-bit --versions | head
```

Select and record a compatible chart version, replacing the placeholder:

```bash
export FLUENT_BIT_CHART_VERSION='REPLACE_WITH_SELECTED_VERSION'
helm upgrade --install fluent-bit fluent/fluent-bit \
  --version "$FLUENT_BIT_CHART_VERSION" --kube-context streamingapp-capstone-dev \
  -n monitoring -f Monitoring/cloudwatch/fluent-bit-values.yaml \
  --set-string "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=$CAPSTONE_LOG_ROLE" \
  --wait --timeout 5m
aws logs tail /streamingapp-capstone/dev/application --since 1h --format short
aws logs tail /streamingapp-capstone/dev/jenkins --since 1h --format short
```

The Fluent Bit input/output config and Jenkins agent JSON currently specify the dev namespace and Mumbai region; change them together if deploying elsewhere. Confirm the logging IAM trust matches `monitoring/fluent-bit` before installing.

If Jenkins logs are empty, on **EC2**, inspect `sudo journalctl -u jenkins.service` and `/opt/aws/amazon-cloudwatch-agent/logs/amazon-cloudwatch-agent.log`. The latter path does not exist on your Mac. Verify newly emitted Jenkins messages arrive; an active agent alone does not prove delivery. Capture application and Jenkins log records (historical screenshots 67 and 68).

## 26. Enable ALB access logs

The persistent root creates a private log bucket with a delivery policy and three-day expiration. Preserve the existing idle-timeout attribute while adding access-log attributes:

```bash
helm upgrade streamingapp helm/streamingapp \
  --kube-context streamingapp-capstone-dev -n streaming-app-dev --reuse-values \
  --set-string "ingress.loadBalancerAttributes=idle_timeout.timeout_seconds=120\,access_logs.s3.enabled=true\,access_logs.s3.bucket=$CAPSTONE_ALB_LOG_BUCKET\,access_logs.s3.prefix=alb" \
  --wait --timeout 10m
curl --fail --silent --show-error -o /dev/null "https://$APP_DOMAIN/"
aws s3 ls "s3://$CAPSTONE_ALB_LOG_BUCKET/alb/AWSLogs/$CAPSTONE_ACCOUNT_ID/" --recursive
```

Delivery is asynchronous. Verify actual log objects after allowing time, not just the bucket existence or test file. Capture delivered access-log evidence (historical screenshot 69).

## 27. Preserve configuration and back up before teardown

Commit reviewed infrastructure, Ansible roles, chart values, pipeline and documentation changes. Keep credentials and backup archives private. The repository contains configuration automation; it does not yet contain a fully verified unattended backup-and-restore system.

The previously created private backup set contains:

| File | Preserves |
| --- | --- |
| `jenkins-home.tar.gz` | Jenkins home, including jobs, plugins and credential-encryption material |
| `sonarqube.dump` | PostgreSQL logical dump for SonarQube |
| `sonarqube-extensions.tar.gz` | SonarQube extensions |
| `host-private-config.tar.gz` | Private host configuration and secrets included during backup |
| `SHA256SUMS` | Integrity manifest |

A directory with only the first two files is **incomplete**. Backups contain credentials and must be protected. Stop writes while taking consistent Jenkins/extension backups; use PostgreSQL backup tooling for its database. A live archive of PostgreSQL volume files is not a substitute for a consistent database backup.

After copying the complete backup to a private Mac location, verify **inside that directory**, not the repository:

```bash
cd /absolute/path/to/your/private/capstone-backup-directory
shasum -a 256 -c SHA256SUMS
```

Expected: all four archives report OK. Checksum success proves transfer integrity, not restore success. A new host restoration must still validate Jenkins ownership, compatible SonarQube/PostgreSQL versions, credentials, current kubeconfig, tunnel token and changed network addresses. Preserve Grafana dashboard JSON separately if its PVC will be deleted.

If restarting SonarQube after backup, use explicit paths so a changed working directory cannot break startup. **EC2:**

```bash
sudo systemctl start jenkins
sudo docker compose --project-directory /opt/capstone-sonarqube \
  --env-file /opt/capstone-sonarqube/.env -f /opt/capstone-sonarqube/compose.yaml start sonarqube
curl --fail --silent --show-error http://127.0.0.1:9000/api/system/status
```

## 28. Tear down only the development session

This step deletes the application and monitoring data in the development cluster and destroys Jenkins EC2. Complete private backups first. Keep the load-balancer controller and EBS CSI running until their managed resources have been removed. Never run blanket account-wide deletion commands in a shared lab account.

**Mac, repository root:**

```bash
export CAPSTONE_VPC_ID="$(terraform -chdir=Terraform/environments/dev output -raw vpc_id)"
kubectl --context streamingapp-capstone-dev get pv \
  -o 'custom-columns=PV:.metadata.name,VOLUME:.spec.csi.volumeHandle,RECLAIM:.spec.persistentVolumeReclaimPolicy'
helm uninstall streamingapp --kube-context streamingapp-capstone-dev -n streaming-app-dev --wait --timeout 10m
aws elbv2 describe-load-balancers \
  --query "LoadBalancers[?VpcId=='${CAPSTONE_VPC_ID}'].{Name:LoadBalancerName,State:State.Code}" --output table
helm uninstall monitoring --kube-context streamingapp-capstone-dev -n monitoring --wait --timeout 10m
kubectl --context streamingapp-capstone-dev get pvc -n monitoring
```

Wait for the ALB to disappear. After confirming you accept loss of the remaining monitoring volumes:

```bash
kubectl --context streamingapp-capstone-dev delete pvc --all -n monitoring --wait=true --timeout=5m
kubectl --context streamingapp-capstone-dev get pv
terraform -chdir=Terraform/environments/dev plan -destroy -input=false -out=destroy-dev.tfplan
```

Review the destroy plan and ensure it is the **dev** root, then:

```bash
terraform -chdir=Terraform/environments/dev apply destroy-dev.tfplan
terraform -chdir=Terraform/environments/dev state list
```

Expected: empty dev state. Check the previously recorded EBS volume IDs in EC2 and verify that project NAT gateways, ALB and EC2 instances are gone. An empty state is not proof that every out-of-band resource was deleted. Preserve bootstrap/persistent resources, Atlas data and private backups. Remove obsolete DNS/NAT allow-list entries. Capture teardown evidence (historical screenshot 70).

## 29. Resume after a teardown

For the working dev environment, use the [single-command dev lifecycle](dev-lifecycle.md) for future sessions. Its `down` command captures the current settings before deletion; its `up` command consumes that checkpoint. The following manual path also applies to older teardowns without a lifecycle checkpoint.

1. Log in again and repeat the session exports in step 2.
2. Verify the private backup checksums and existing bootstrap/persistent plans.
3. Refresh Terraform outputs from step 5; do not create duplicate persistent resources.
4. Supply current administrator IP, SSH key, admin role and AMI inputs in step 9.
5. Recreate dev infrastructure, then update Atlas with new NAT IPs.
6. Reinstall controllers, secrets and application using the recorded release image tag, or rebuild all images intentionally.
7. Update application DNS to the new ALB; update Jenkins inventory through `CAPSTONE_JENKINS_IP` and the monitoring private-IP target.
8. Recreate monitoring credentials/configuration. Use the recovery command below to restore the Jenkins EC2 tools and refresh Jenkins’ kubeconfig.
9. Verify login, upload/playback, chat, pipeline, alert delivery and logs before calling recovery complete.

Do not reuse a saved Terraform plan from before teardown, an old ALB hostname or an old IP address.

### Restore the dev Jenkins and SonarQube host

After Terraform recreates the dev host, sign in with the intended AWS profile. Verify its SSH host fingerprint and accept it once as in step 19. From the repository root on your Mac, run:

```bash
export AWS_PROFILE=streamingapp
export AWS_REGION=ap-south-1
./scripts/recover-dev-tools.sh "$HOME/PrivateBackups/capstone/capstone-backup-20261031T074819Z"
```

Use your private backup directory containing the four archives and their checksum manifest. The command reads the current Jenkins IP and EKS name from Terraform, provisions tools through Ansible, transfers the backup over SSH, verifies it, and restores the existing Cloudflare token and SonarQube Compose settings. It refreshes Jenkins’ private kubeconfig using the EC2 instance role.

The restore expects the capstone backup layout: Jenkins under `jenkins/`, extensions relative to their volume root, and the private files at `etc/cloudflared/token`, `opt/capstone-sonarqube/compose.yaml` and `opt/capstone-sonarqube/.env`. The previous Jenkins home is preserved during a fresh restore. A rerun keeps an existing capstone job, populated SonarQube database and nonempty private config files. Use a trusted, verified backup. The remote private copy occupies space under `/var/backups/capstone-recovery`.

The playbook waits for Jenkins login through nginx on port 8081 and for SonarQube to return JSON status `UP` through nginx on port 8082. A SonarQube HTTP 200 with status `STARTING` keeps the check running. On a new host the connector starts after these checks. Keep the existing published Cloudflare routes, Access policy and a valid connector token. After the play succeeds, sign in through each public URL and confirm the Jenkins build history and previous SonarQube project analysis. If the SonarQube wait times out, inspect `sudo docker compose logs --tail=80 sonarqube db` from `/opt/capstone-sonarqube` on EC2. Leave the database volume in place while diagnosing startup.

## Troubleshooting checkpoints

| Symptom | Check next |
| --- | --- |
| Compose configuration not found | Use the repository-root `-f StreamingApp/docker-compose.yml` commands |
| Missing Terraform variables | Repeat session exports; `-input=false` exposes missing inputs immediately |
| State lock after Ctrl+Z | Resume the suspended job with `fg` and cancel cleanly; never force-unlock an active writer |
| EKS forbidden | Check IAM access entry and intended namespace permissions |
| Nodes fail to join | Inspect node group health, private routing/NAT, security groups and add-on compatibility |
| Image scan not found by tag | Inspect OCI index and query the linux/amd64 child digest |
| `/streaming/streaming/` 404 | Rebuild frontend with streaming API base `/api` |
| Helm annotation bool error | Quote annotations or use `--set-string` |
| SSH timeout | Refresh EC2 public IP and administrator `/32`; check instance state and security group |
| Cloudflare tunnel fails | Check token file, permissions and service logs without exposing the token |
| SonarQube resets connection | Wait for startup; inspect container logs and memory if persistent |
| Backup checksum file missing | Enter the actual private backup directory and confirm all files exist |

## Evidence and remaining work

Use [screenshots/eks](screenshots/eks) and the other screenshot folders for existing evidence. Capture only milestone results. The previous run includes application, IAM, HPA, monitoring, CI/CD, log delivery and teardown screenshots; do not represent them as proof of a new run without repeating verification.

See the [architecture directory](../Architecture), [Terraform guide](../Terraform/README.md), [Ansible guide](../Ansible/README.md), and source configuration for implementation details. Before a production rollout, complete account/environment parameterization, staging/prod separation and approvals, image-vulnerability remediation, automated tested backups/restores, and recovery testing. The current development setup and manual bootstrap steps do not establish production readiness by themselves.
