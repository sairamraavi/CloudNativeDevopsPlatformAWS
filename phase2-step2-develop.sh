#!/usr/bin/env bash
# StreamingApp capstone - develop branch guided deployment
# Source: setup-process.md + supplied develop branch. Region/account are the only
# mandated deployment-target overrides. No teardown/destroy operations are included.
set -Eeuo pipefail
IFS=$'\n\t'

readonly AWS_ACCOUNT_ID='529976312668'
readonly AWS_REGION='ap-southeast-2'
readonly AWS_PROFILE_NAME='personal'
readonly APP_DOMAIN='streaming.sairamraavi.com'
readonly PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly STATE_BUCKET='streamingapp-tfstate-8a4b578417838a617bba947a4f'
readonly CLUSTER_CONTEXT='streamingapp-capstone-dev'
readonly NAMESPACE='streaming-app-dev'

log(){ printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
die(){ printf '\nERROR: %s\n' "$*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1. Install it as described by the project setup guide."; }
confirm(){ local answer; read -r -p "$1 [y/N] " answer; [[ "$answer" == [yY] || "$answer" == [yY][eE][sS] ]]; }
ask(){ local __name="$1" __prompt="$2" __value; read -r -p "$__prompt" __value; [[ -n "$__value" ]] || die "A value is required: $__prompt"; printf -v "$__name" '%s' "$__value"; }
run(){ printf '\n+ '; printf '%q ' "$@"; printf '\n'; "$@"; }

# Compose reports containers as "Started" before their applications are ready.
# Use bounded readiness checks instead of a single immediate curl.
wait_for_health(){
  local name="$1" url="$2" attempts="${3:-12}" i
  printf '\nWaiting for %s at %s\n' "$name" "$url"
  for ((i=1; i<=attempts; i++)); do
    if curl -fsS --max-time 5 "$url" >/dev/null 2>&1; then
      printf '%s is healthy (attempt %s/%s).\n' "$name" "$i" "$attempts"
      return 0
    fi
    if (( i < attempts )); then
      printf '%s not ready (%s/%s); retrying in 5 seconds.\n' "$name" "$i" "$attempts"
      sleep 5
    fi
  done
  printf 'ERROR: %s did not become healthy: %s\n' "$name" "$url" >&2
  docker compose -f StreamingApp/docker-compose.yml ps -a >&2 || true
  docker compose -f StreamingApp/docker-compose.yml logs --tail=80 >&2 || true
  return 1
}

wait_for_tcp_port(){
  local name="$1" port="$2" attempts="${3:-12}" i
  printf '\nWaiting for %s TCP port %s\n' "$name" "$port"
  for ((i=1; i<=attempts; i++)); do
    if ( : > "/dev/tcp/127.0.0.1/$port" ) 2>/dev/null; then
      printf '%s is accepting TCP connections (attempt %s/%s).\n' "$name" "$i" "$attempts"
      return 0
    fi
    if (( i < attempts )); then
      printf '%s port not ready (%s/%s); retrying in 5 seconds.\n' "$name" "$i" "$attempts"
      sleep 5
    fi
  done
  printf 'ERROR: %s did not open TCP port %s.\n' "$name" "$port" >&2
  docker compose -f StreamingApp/docker-compose.yml ps -a >&2 || true
  docker compose -f StreamingApp/docker-compose.yml logs --tail=80 >&2 || true
  return 1
}

wait_for_mongo(){
  local attempts="${1:-12}" i
  printf '\nWaiting for MongoDB ping\n'
  for ((i=1; i<=attempts; i++)); do
    if docker compose -f StreamingApp/docker-compose.yml exec -T mongo mongosh --quiet --eval 'db.adminCommand({ ping: 1 })' >/dev/null 2>&1; then
      printf 'MongoDB ping succeeded (attempt %s/%s).\n' "$i" "$attempts"
      return 0
    fi
    if (( i < attempts )); then
      printf 'MongoDB not ready (%s/%s); retrying in 5 seconds.\n' "$i" "$attempts"
      sleep 5
    fi
  done
  printf 'ERROR: MongoDB did not become ready.\n' >&2
  docker compose -f StreamingApp/docker-compose.yml logs --tail=80 mongo >&2 || true
  return 1
}

trap 'rc=$?; printf "\nStopped at line %s (exit %s). No later phases were run.\n" "$LINENO" "$rc" >&2; exit "$rc"' ERR

cd "$PROJECT_ROOT"
[[ -d Terraform/bootstrap && -d Terraform/persistent && -d Terraform/environments/dev && -d StreamingApp ]] || die 'Run this script from the root of the supplied develop checkout.'

log '1/10 - Confirm branch and required local tools'
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  branch="$(git branch --show-current)"
  [[ "$branch" == develop ]] || die "Expected develop branch, found '$branch'. Checkout develop before running."
else
  log 'ZIP checkout has no .git metadata; continuing with supplied develop source snapshot.'
fi
for c in aws terraform docker kubectl helm ansible python3 curl; do need "$c"; done
run terraform version
run docker version
run kubectl version --client
run helm version --short
run ansible --version

log '2/10 - Set fixed AWS target and verify identity'
export AWS_PROFILE="$AWS_PROFILE_NAME"
export AWS_REGION AWS_DEFAULT_REGION="$AWS_REGION"
export AWS_PAGER=''
export APP_DOMAIN
export CAPSTONE_ACCOUNT_ID="$AWS_ACCOUNT_ID"
export TF_VAR_expected_account_id="$AWS_ACCOUNT_ID"
export TF_VAR_aws_region="$AWS_REGION"
export TF_VAR_application_domain="$APP_DOMAIN"
export TF_VAR_media_allowed_origins="$(printf '["https://%s","http://localhost:3000"]' "$APP_DOMAIN")"
run aws sts get-caller-identity --query '{Account:Account,Arn:Arn}' --output json
actual_account="$(aws sts get-caller-identity --query Account --output text)"
[[ "$actual_account" == "$AWS_ACCOUNT_ID" ]] || die "AWS identity is $actual_account, expected $AWS_ACCOUNT_ID. No resources changed."

log '3/10 - Local application validation (setup guide step 3)'
if [[ ! -f StreamingApp/.env ]]; then
  [[ -f StreamingApp/.env.example ]] || die 'StreamingApp/.env.example is missing.'
  cp StreamingApp/.env.example StreamingApp/.env
  chmod 600 StreamingApp/.env
  log 'Created StreamingApp/.env from the checked-in example. Fill required private values before continuing.'
  die 'Complete StreamingApp/.env privately, then rerun this script.'
fi
run docker compose -f StreamingApp/docker-compose.yml config --quiet
if confirm 'Build and start the local application exactly as in setup step 3?'; then
  run docker compose -f StreamingApp/docker-compose.yml up -d --build
  run docker compose -f StreamingApp/docker-compose.yml ps -a

  # Verified HTTP health endpoints from the supplied project run:
  wait_for_health 'Frontend' 'http://localhost:3000/'
  wait_for_health 'Auth' 'http://localhost:3001/health'
  wait_for_health 'Streaming' 'http://localhost:3002/api/health'
  wait_for_health 'Admin' 'http://localhost:3003/api/health'

  # Chat's root path returned HTTP 404 in the supplied validation log; that is
  # not a health endpoint. Check that its configured port is accepting TCP.
  wait_for_tcp_port 'Chat service' 3004
  wait_for_mongo
  run docker compose -f StreamingApp/docker-compose.yml ps -a
else
  die 'Local validation was not approved; stopping.'
fi

log '4/10 - Check remote Terraform state before touching infrastructure'
aws s3api head-bucket --bucket "$STATE_BUCKET" --region "$AWS_REGION" >/dev/null
log "Existing state bucket verified: $STATE_BUCKET"
log 'The supplied AWS inspection found shared/ecr.tfstate, but did not establish bootstrap/terraform.tfstate or persistent/terraform.tfstate.'
for key in bootstrap/terraform.tfstate persistent/terraform.tfstate environments/dev/terraform.tfstate; do
  if aws s3api head-object --bucket "$STATE_BUCKET" --key "$key" --region "$AWS_REGION" >/dev/null 2>&1; then
    printf 'FOUND state key: %s\n' "$key"
  else
    printf 'MISSING state key: %s\n' "$key"
  fi
done
if ! aws s3api head-object --bucket "$STATE_BUCKET" --key bootstrap/terraform.tfstate --region "$AWS_REGION" >/dev/null 2>&1; then
  die 'Bootstrap state key is absent. The setup guide has a first-deployment migration path, but the supplied AWS evidence shows an existing bucket and a different shared/ecr.tfstate key. I will not initialize an empty bootstrap state or risk recreating the existing bucket. Resolve the bootstrap state mapping first.'
fi

log '5/10 - Initialize and inspect bootstrap state (setup guide step 4)'
run terraform -chdir=Terraform/bootstrap init -input=false
run terraform -chdir=Terraform/bootstrap plan -input=false
confirm 'Bootstrap plan reviewed. Continue to persistent resources?' || die 'Stopped before persistent resources.'

log '6/10 - Persistent resources (setup guide steps 5-7)'
run terraform -chdir=Terraform/persistent init -input=false \
  -backend-config="bucket=$STATE_BUCKET" \
  -backend-config='key=persistent/terraform.tfstate' \
  -backend-config="region=$AWS_REGION" \
  -backend-config='encrypt=true' \
  -backend-config='use_lockfile=true'
run terraform -chdir=Terraform/persistent validate
run terraform -chdir=Terraform/persistent plan -input=false -out=persistent.tfplan
confirm 'Review the persistent plan. Apply exactly this saved plan?' || die 'Persistent apply not approved.'
run terraform -chdir=Terraform/persistent apply -input=false persistent.tfplan
export CAPSTONE_MEDIA_BUCKET="$(terraform -chdir=Terraform/persistent output -raw media_bucket_name)"
export TF_VAR_media_bucket_arn="$(terraform -chdir=Terraform/persistent output -raw media_bucket_arn)"
export TF_VAR_application_secret_arn="$(terraform -chdir=Terraform/persistent output -raw application_dev_secret_arn)"
export CAPSTONE_CERT_ARN="$(terraform -chdir=Terraform/persistent output -raw application_certificate_arn)"
export CAPSTONE_ALB_LOG_BUCKET="$(terraform -chdir=Terraform/persistent output -raw alb_logs_bucket_name)"

log 'MANUAL GATE - Atlas, ACM validation and application secret values'
printf '%s\n' \
  'Complete setup guide steps 6 and 7 outside this script:' \
  ' - Add the ACM DNS validation CNAME records in Cloudflare and wait for ISSUED.' \
  ' - Configure the Atlas cluster, database user and restricted network access.' \
  ' - Set MONGO_URI and JWT_SECRET in the existing Secrets Manager secret.' \
  ' - Do not paste or print secret values in this terminal.'
confirm 'Have you completed those exact manual steps and verified AWSCURRENT plus ACM ISSUED?' || die 'Manual integration gate not complete.'

log '7/10 - Build and publish the five existing service images (setup guide step 8)'
export ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
export IMAGE_TAG="$(git rev-parse --short=12 HEAD 2>/dev/null || printf 'develop')-$(date -u +%Y%m%d%H%M%S)"
aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$ECR_REGISTRY"
run docker build --pull --platform linux/amd64 -t "$ECR_REGISTRY/streamingapp-capstone-auth:$IMAGE_TAG" StreamingApp/backend/authService
for service in streaming admin chat; do
  run docker build --pull --platform linux/amd64 -f "StreamingApp/backend/${service}Service/Dockerfile" -t "$ECR_REGISTRY/streamingapp-capstone-$service:$IMAGE_TAG" StreamingApp/backend
done
run docker build --pull --platform linux/amd64 \
  --build-arg REACT_APP_AUTH_API_URL=/api \
  --build-arg REACT_APP_STREAMING_API_URL=/api \
  --build-arg REACT_APP_STREAMING_PUBLIC_URL="https://$APP_DOMAIN" \
  --build-arg REACT_APP_ADMIN_API_URL=/api/admin \
  --build-arg REACT_APP_CHAT_API_URL=/api/chat \
  --build-arg REACT_APP_CHAT_SOCKET_URL="https://$APP_DOMAIN" \
  -t "$ECR_REGISTRY/streamingapp-capstone-frontend:$IMAGE_TAG" StreamingApp/frontend
run docker run --rm --platform linux/amd64 "$ECR_REGISTRY/streamingapp-capstone-frontend:$IMAGE_TAG" nginx -t
for service in auth streaming admin chat frontend; do
  run docker push "$ECR_REGISTRY/streamingapp-capstone-$service:$IMAGE_TAG"
done
printf '\nIMAGE_TAG=%s\nECR_REGISTRY=%s\n' "$IMAGE_TAG" "$ECR_REGISTRY"

log '8/10 - Collect existing dev Terraform inputs (setup guide step 9)'
mapfile -t AZS < <(aws ec2 describe-availability-zones --region "$AWS_REGION" --filters Name=state,Values=available --query 'AvailabilityZones[].ZoneName' --output text | tr '\t' '\n' | head -n 2)
[[ "${#AZS[@]}" -eq 2 ]] || die 'Could not identify two available AZs in Sydney.'
export TF_VAR_availability_zones="[\"${AZS[0]}\",\"${AZS[1]}\"]"
export TF_VAR_nat_mode='per_az'
ADMIN_IP="$(curl -4 --fail --silent --show-error https://checkip.amazonaws.com | tr -d '\r\n')"
export TF_VAR_eks_public_access_cidrs="[\"${ADMIN_IP}/32\"]"
export TF_VAR_jenkins_admin_cidr="${ADMIN_IP}/32"
KEY_PATH="$HOME/.ssh/streamingapp-capstone-jenkins"
if [[ ! -s "$KEY_PATH" ]]; then
  mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
  run ssh-keygen -t ed25519 -f "$KEY_PATH" -C streamingapp-capstone-jenkins
fi
export TF_VAR_jenkins_public_key_path="$KEY_PATH.pub"
ask TF_VAR_EKS_ROLE 'Enter existing EKS administrator IAM role ARN (not STS assumed-role ARN): '
export TF_VAR_eks_admin_role_arn="$TF_VAR_EKS_ROLE"
ask TF_VAR_JENKINS_AMI 'Enter verified Ubuntu 24.04 AMD64 AMI ID in ap-southeast-2: '
export TF_VAR_jenkins_ami_id="$TF_VAR_JENKINS_AMI"

log '9/10 - Development infrastructure (setup guide step 10)'
run terraform -chdir=Terraform/environments/dev init -input=false \
  -backend-config="bucket=$STATE_BUCKET" \
  -backend-config='key=environments/dev/terraform.tfstate' \
  -backend-config="region=$AWS_REGION" \
  -backend-config='encrypt=true' \
  -backend-config='use_lockfile=true'
run terraform -chdir=Terraform/environments/dev validate
run terraform -chdir=Terraform/environments/dev plan -input=false -out=dev.tfplan
confirm 'Review the dev plan. Apply exactly this saved plan (creates EKS, VPC/NAT, Jenkins and related resources)?' || die 'Dev apply not approved.'
run terraform -chdir=Terraform/environments/dev apply -input=false dev.tfplan
export CAPSTONE_CLUSTER_NAME="$(terraform -chdir=Terraform/environments/dev output -raw eks_cluster_name)"
export CAPSTONE_VPC_ID="$(terraform -chdir=Terraform/environments/dev output -raw vpc_id)"
export CAPSTONE_JENKINS_IP="$(terraform -chdir=Terraform/environments/dev output -raw jenkins_public_ip)"
run aws eks update-kubeconfig --region "$AWS_REGION" --name "$CAPSTONE_CLUSTER_NAME" --alias "$CLUSTER_CONTEXT"
run kubectl --context "$CLUSTER_CONTEXT" auth can-i list nodes
run kubectl --context "$CLUSTER_CONTEXT" get nodes -L topology.kubernetes.io/zone
run kubectl --context "$CLUSTER_CONTEXT" get pods -n kube-system
run terraform -chdir=Terraform/environments/dev output nat_public_ips

log '10/10 - Stop at manual integration boundary'
printf '%s\n' \
 'The remaining setup guide steps 11-26 require chart-version selection, Atlas NAT allow-list updates, External Secrets, controllers, Helm application install, monitoring/SES configuration, Ansible/Jenkins/SonarQube setup, Cloudflare Tunnel/webhook, Fluent Bit and ALB log verification.' \
 'Those actions are not collapsed into guessed values here. Use the exact checked-in charts, values, roles and Jenkinsfile as described by setup-process.md.' \
 'No teardown or destroy operation is present in this script.'
printf '\nDeployment checkpoint reached. IMAGE_TAG=%s\n' "$IMAGE_TAG"