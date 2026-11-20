#!/usr/bin/env bash
# Rebuild the AWS foundation created for this project:
# 1) Terraform state bucket (only if absent)
# 2) Shared ECR repositories
# 3) Staging VPC, EKS, IAM, S3 and Secrets Manager metadata
#
# This script NEVER destroys resources. It creates/reconciles infrastructure.
# Run from any directory; paths are resolved relative to this script's repo root.

set -Eeuo pipefail

# ---------- Project-specific settings ----------
AWS_PROFILE="${AWS_PROFILE:-personal}"
AWS_REGION="${AWS_REGION:-ap-southeast-2}"
EXPECTED_ACCOUNT_ID="${EXPECTED_ACCOUNT_ID:-529976312668}"
STATE_BUCKET="${STATE_BUCKET:-streamingapp-tfstate-8a4b578417838a617bba947a4f}"
ADMIN_ROLE_ARN="${ADMIN_ROLE_ARN:-arn:aws:iam::529976312668:role/managed/AccountFullAccessRole}"
STAGING_TFVARS="${STAGING_TFVARS:-Terraform/environments/staging/staging.tfvars}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

export AWS_PROFILE AWS_REGION
export AWS_DEFAULT_REGION="$AWS_REGION"
export AWS_PAGER=""

log()  { printf '\n\033[1;34m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\n\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\n\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

need() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

confirm() {
  local prompt="$1" answer
  printf '\n%s\nType YES to continue: ' "$prompt"
  read -r answer
  [[ "$answer" == "YES" ]] || die "Stopped by user. No further Terraform apply was run."
}

terraform_root() {
  local dir="$1" backend_key="$2"
  shift 2
  log "Initializing Terraform root: $dir"
  terraform -chdir="$dir" init -input=false -reconfigure \
    -backend-config="bucket=$STATE_BUCKET" \
    -backend-config="key=$backend_key" \
    -backend-config="region=$AWS_REGION" \
    -backend-config="encrypt=true" \
    -backend-config="use_lockfile=true"

  terraform -chdir="$dir" fmt -check -recursive
  terraform -chdir="$dir" validate
}

apply_reviewed_plan() {
  local dir="$1" plan="$2" description="$3"
  log "Creating plan for: $description"
  terraform -chdir="$dir" plan -input=false "$@" -out="$plan"
  terraform -chdir="$dir" show -no-color "$plan"

  confirm "Review the plan above. Confirm the AWS account, region, and resource actions for: $description"
  terraform -chdir="$dir" apply -input=false "$plan"
}

for tool in aws terraform; do need "$tool"; done

[[ -d Terraform/bootstrap ]] || die "Run this script from the repository layout; Terraform/bootstrap is missing."
[[ -d Terraform/shared/ecr ]] || die "Terraform/shared/ecr is missing."
[[ -d Terraform/environments/staging ]] || die "Terraform/environments/staging is missing."

log "Checking AWS identity"
IDENTITY="$(aws sts get-caller-identity --query '{Account:Account,Arn:Arn}' --output json)"
printf '%s\n' "$IDENTITY"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
[[ "$ACCOUNT" == "$EXPECTED_ACCOUNT_ID" ]] ||
  die "Wrong AWS account. Expected $EXPECTED_ACCOUNT_ID but got $ACCOUNT."

# ---------- 1. Terraform state bucket ----------
log "Checking Terraform state bucket: $STATE_BUCKET"
if aws s3api head-bucket --bucket "$STATE_BUCKET" >/dev/null 2>&1; then
  log "State bucket already exists. Reusing it; will not create a replacement."
else
  warn "State bucket is missing. The bootstrap root will recreate it."
  # Bootstrap intentionally uses local state because it creates the remote backend.
  terraform -chdir=Terraform/bootstrap init -backend=false -input=false
  terraform -chdir=Terraform/bootstrap fmt -check -recursive
  terraform -chdir=Terraform/bootstrap validate

  BOOTSTRAP_PLAN="bootstrap-recovery.tfplan"
  terraform -chdir=Terraform/bootstrap plan -input=false \
    -var="aws_region=$AWS_REGION" \
    -var="expected_account_id=$EXPECTED_ACCOUNT_ID" \
    -out="$BOOTSTRAP_PLAN"
  terraform -chdir=Terraform/bootstrap show -no-color "$BOOTSTRAP_PLAN"
  confirm "This creates the remote Terraform state bucket and its protections."
  terraform -chdir=Terraform/bootstrap apply -input=false "$BOOTSTRAP_PLAN"

  CREATED_BUCKET="$(terraform -chdir=Terraform/bootstrap output -raw terraform_state_bucket_name)"
  [[ "$CREATED_BUCKET" == "$STATE_BUCKET" ]] ||
    die "Bootstrap created bucket '$CREATED_BUCKET', but this script expects '$STATE_BUCKET'. Update STATE_BUCKET and rerun."
fi

# ---------- 2. Shared ECR ----------
log "Provisioning shared ECR repositories"
terraform_root "Terraform/shared/ecr" "shared/ecr.tfstate"
ECR_STATE="$(terraform -chdir=Terraform/shared/ecr state list)"
if [[ -z "$ECR_STATE" ]]; then
  EXISTING_ECR="$(aws ecr describe-repositories --region "$AWS_REGION" --query 'repositories[].repositoryName' --output text 2>/dev/null || true)"
  [[ -z "$EXISTING_ECR" ]] || die "ECR repositories exist but shared/ecr Terraform state is empty. Recover/import state first; refusing duplicate creation."
  warn "Shared ECR state is empty and no repositories were found; proceeding with first creation."
fi
ECR_PLAN="ecr-recovery.tfplan"
terraform -chdir=Terraform/shared/ecr plan -input=false \
  -var="expected_account_id=$EXPECTED_ACCOUNT_ID" \
  -var="aws_region=$AWS_REGION" \
  -out="$ECR_PLAN"
terraform -chdir=Terraform/shared/ecr show -no-color "$ECR_PLAN"
confirm "This reconciles the five shared ECR repositories. Existing repositories should be in state."
terraform -chdir=Terraform/shared/ecr apply -input=false "$ECR_PLAN"

# ---------- 3. Staging AWS infrastructure ----------
log "Checking staging inputs"
[[ -f "$STAGING_TFVARS" ]] ||
  die "Missing $STAGING_TFVARS. Restore the ignored local tfvars file; do not commit it."

# Verify the tfvars are configured for this account/region. Terraform validation/plan
# is the authoritative check for the remaining required variables.
grep -q "$EXPECTED_ACCOUNT_ID" "$STAGING_TFVARS" ||
  die "The staging tfvars file does not contain expected account ID $EXPECTED_ACCOUNT_ID."
grep -q "$AWS_REGION" "$STAGING_TFVARS" ||
  die "The staging tfvars file does not contain expected region $AWS_REGION."

terraform_root "Terraform/environments/staging" "staging/terraform.tfstate"
STAGING_STATE="$(terraform -chdir=Terraform/environments/staging state list)"
if [[ -z "$STAGING_STATE" ]]; then
  EXISTING_CLUSTER="$(aws eks list-clusters --region "$AWS_REGION" --query "clusters[?@=='streamingapp-capstone-staging-eks'] | [0]" --output text 2>/dev/null || true)"
  EXISTING_STAGING_VPC="$(aws ec2 describe-vpcs --region "$AWS_REGION" --filters "Name=tag:Project,Values=streamingapp-capstone" "Name=tag:Environment,Values=staging" --query 'Vpcs[0].VpcId' --output text 2>/dev/null || true)"
  [[ "$EXISTING_CLUSTER" == "None" && "$EXISTING_STAGING_VPC" == "None" ]] ||
    die "Staging resources appear to exist but staging Terraform state is empty. Recover/import state first; refusing duplicate creation."
  warn "Staging state is empty and no matching cluster/VPC were found; proceeding with first creation."
fi
STAGING_PLAN="staging-recovery.tfplan"
terraform -chdir=Terraform/environments/staging plan -input=false \
  -var-file="$(basename "$STAGING_TFVARS")" \
  -out="$STAGING_PLAN"
terraform -chdir=Terraform/environments/staging show -no-color "$STAGING_PLAN"
confirm "This provisions/reconciles staging networking, EKS, IAM, add-ons, media bucket and secret metadata."
terraform -chdir=Terraform/environments/staging apply -input=false "$STAGING_PLAN"

# ---------- 4. Post-provision verification ----------
log "Verifying staging EKS cluster"
CLUSTER_NAME="streamingapp-capstone-staging-eks"
if aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
  aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" \
    --query 'cluster.{Name:name,Status:status,Version:version,Endpoint:endpoint}' --output table
  warn "EKS control-plane exists. Node readiness and Kubernetes add-ons must still be checked with kubectl."
else
  warn "Expected cluster name '$CLUSTER_NAME' was not found. Check Terraform outputs and actual cluster naming."
fi

log "AWS foundation recovery completed."
cat <<'EOF'

What this script has restored:
  - Terraform state bucket (only if it was absent)
  - Shared ECR repositories
  - Staging VPC/networking, EKS, IAM roles/policies, EKS add-ons,
    staging media bucket and Secrets Manager secret metadata

Not restored by this script:
  - Secrets Manager secret values (Mongo URI, JWT secret, etc.)
  - ECR image contents if repositories/images were deleted
  - MongoDB Atlas, Cloudflare DNS/certificate validation
  - Kubernetes Helm releases, namespaces, app workloads, ingress/ALB
  - Jenkins EC2, Ansible configuration, monitoring stack, backups
  - Application images/build and deployment

IMPORTANT:from pathlib import Path

script = r'''[CmdletBinding()]
param(
    [switch]$Apply,
    [switch]$SkipStaging
)

# Rebuilds ONLY the AWS infrastructure actually implemented in this repository:
#   1) Terraform state bucket (Terraform/bootstrap; local bootstrap state)
#   2) Shared ECR repositories (Terraform/shared/ecr)
#   3) Staging AWS foundation (Terraform/environments/staging)
#
# Default mode is PLAN ONLY. Use -Apply to permit per-layer confirmation.
# This script does not deploy application workloads or external services.

$ErrorActionPreference = "Stop"
$Region = "ap-southeast-2"
$ExpectedAccount = "529976312668"
$Profile = "personal"
$KnownStateBucket = "streamingapp-tfstate-8a4b578417838a617bba947a4f"

$RepoRoot = $PSScriptRoot
$BootstrapDir = Join-Path $RepoRoot "Terraform\bootstrap"
$EcrDir = Join-Path $RepoRoot "Terraform\shared\ecr"
$StagingDir = Join-Path $RepoRoot "Terraform\environments\staging"
$StagingTfvars = Join-Path $StagingDir "staging.tfvars"

function Stop-Recovery([string]$Message) {
    throw $Message
}

function Invoke-Checked {
    param([string]$File, [string[]]$Arguments, [string]$Description)
    Write-Host "`n>>> $Description" -ForegroundColor Cyan
    & $File @Arguments
    if ($LASTEXITCODE -ne 0) {
        Stop-Recovery "$Description failed (exit code $LASTEXITCODE)."
    }
}

function Confirm-Layer([string]$Layer) {
    if (-not $Apply) {
        Write-Host "PLAN ONLY: $Layer was not applied. Rerun with -Apply after reviewing." -ForegroundColor Yellow
        return $false
    }
    $answer = Read-Host "Type APPLY-$Layer to apply this exact saved Terraform plan"
    return ($answer -ceq "APPLY-$Layer")
}

function Test-S3Object([string]$Bucket, [string]$Key) {
    & aws s3api head-object --bucket $Bucket --key $Key --profile $Profile --region $Region 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Get-ExpectedEcrRepositories {
    return @(
        "streamingapp-capstone-streaming",
        "streamingapp-capstone-auth",
        "streamingapp-capstone-admin",
        "streamingapp-capstone-chat",
        "streamingapp-capstone-frontend"
    )
}

function Get-ExistingExpectedEcr {
    $json = & aws ecr describe-repositories --profile $Profile --region $Region --output json 2>$null
    if ($LASTEXITCODE -ne 0) { return @() }
    $all = @((($json | ConvertFrom-Json).repositories | ForEach-Object { $_.repositoryName }))
    return @($all | Where-Object { $_ -in (Get-ExpectedEcrRepositories) })
}

function Invoke-PlanAndMaybeApply {
    param(
        [string]$Directory,
        [string[]]$PlanArgs,
        [string]$PlanFile,
        [string]$Layer,
        [string]$ConfirmationToken
    )

    Invoke-Checked "terraform" (@("-chdir=$Directory", "fmt", "-check", "-recursive")) "$Layer formatting check"
    Invoke-Checked "terraform" (@("-chdir=$Directory", "validate", "-no-color")) "$Layer validation"
    Invoke-Checked "terraform" (@("-chdir=$Directory", "plan", "-input=false", "-no-color", "-out=$PlanFile") + $PlanArgs) "$Layer plan"

    $shown = & terraform "-chdir=$Directory" "show" "-no-color" $PlanFile
    if ($LASTEXITCODE -ne 0) { Stop-Recovery "Could not display saved plan for $Layer." }
    $shown | Select-String -Pattern "^(  # |Plan:|No changes\.)" | ForEach-Object { Write-Host $_.Line }

    if (Confirm-Layer $ConfirmationToken) {
        Invoke-Checked "terraform" @("-chdir=$Directory", "apply", "-input=false", "-no-color", $PlanFile) "$Layer apply"
    } else {
        Write-Host "Skipped apply for $Layer." -ForegroundColor Yellow
    }
}

# ----- Preflight -----
foreach ($tool in @("aws", "terraform")) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        Stop-Recovery "Required command '$tool' is not installed or not on PATH."
    }
}
foreach ($dir in @($BootstrapDir, $EcrDir, $StagingDir)) {
    if (-not (Test-Path $dir)) { Stop-Recovery "Missing Terraform directory: $dir" }
}
if (-not $SkipStaging -and -not (Test-Path $StagingTfvars)) {
    Stop-Recovery "Missing $StagingTfvars. Restore this ignored local file; do not commit it."
}

$env:AWS_PROFILE = $Profile
$env:AWS_DEFAULT_REGION = $Region
$env:AWS_REGION = $Region
$env:AWS_PAGER = ""

Write-Host "`nAWS recovery target" -ForegroundColor Cyan
Write-Host "Repository: $RepoRoot"
Write-Host "Account:    $ExpectedAccount"
Write-Host "Region:     $Region"
Write-Host "Profile:    $Profile"
Write-Host "Mode:       $(if ($Apply) { 'APPLY (typed confirmation per layer)' } else { 'PLAN ONLY' })"

$identityText = & aws sts get-caller-identity --profile $Profile --region $Region --output json
if ($LASTEXITCODE -ne 0) { Stop-Recovery "AWS authentication failed. Refresh the personal profile credentials first." }
$identity = $identityText | ConvertFrom-Json
if ($identity.Account -ne $ExpectedAccount) {
    Stop-Recovery "Wrong AWS account. Expected $ExpectedAccount; received $($identity.Account)."
}
Write-Host "Verified identity: $($identity.Arn)" -ForegroundColor Green

# ----- Discover current state bucket -----
$stateBucket = $KnownStateBucket
& aws s3api head-bucket --bucket $stateBucket --profile $Profile --region $Region 2>$null | Out-Null
$stateBucketExists = ($LASTEXITCODE -eq 0)

# If the state bucket is gone, check for surviving resources before creating a
# new backend. A missing state bucket does NOT mean the AWS resources are gone.
if (-not $stateBucketExists) {
    Write-Host "Known Terraform state bucket is absent. Checking for surviving managed resources..." -ForegroundColor Yellow

    $survivingEcr = Get-ExistingExpectedEcr
    $clustersText = & aws eks list-clusters --profile $Profile --region $Region --output json
    if ($LASTEXITCODE -ne 0) { Stop-Recovery "Could not inspect EKS clusters; refusing bootstrap." }
    $clusters = @((($clustersText | ConvertFrom-Json).clusters))
    $vpcText = & aws ec2 describe-vpcs --filters "Name=cidr-block,Values=10.10.0.0/16" --profile $Profile --region $Region --output json
    if ($LASTEXITCODE -ne 0) { Stop-Recovery "Could not inspect VPCs; refusing bootstrap." }
    $survivingVpc = @((($vpcText | ConvertFrom-Json).Vpcs)).Count -gt 0

    if ($survivingEcr.Count -gt 0 -or $clusters.Count -gt 0 -or $survivingVpc) {
        Stop-Recovery "The Terraform state bucket is missing but managed AWS resources still exist (ECR/cluster/VPC detected). Do NOT recreate from empty state. Recover the state object versions/backups or import existing resources first."
    }

    Write-Host "No expected ECR repositories, EKS clusters, or staging VPC were detected." -ForegroundColor Yellow
    Invoke-Checked "terraform" @("-chdir=$BootstrapDir", "init", "-backend=false", "-input=false") "Bootstrap local-state initialization"
    Invoke-Checked "terraform" @("-chdir=$BootstrapDir", "fmt", "-check", "-recursive") "Bootstrap formatting check"
    Invoke-Checked "terraform" @("-chdir=$BootstrapDir", "validate", "-no-color") "Bootstrap validation"

    $bootstrapPlan = "bootstrap-recovery.tfplan"
    Invoke-Checked "terraform" @(
        "-chdir=$BootstrapDir", "plan", "-input=false", "-no-color",
        "-out=$bootstrapPlan",
        "-var=expected_account_id=$ExpectedAccount",
        "-var=aws_region=$Region"
    ) "Bootstrap plan"

    $bootstrapShow = & terraform "-chdir=$BootstrapDir" "show" "-no-color" $bootstrapPlan
    if ($LASTEXITCODE -ne 0) { Stop-Recovery "Could not display bootstrap plan." }
    $bootstrapShow | Select-String -Pattern "^(  # |Plan:|No changes\.)" | ForEach-Object { Write-Host $_.Line }

    if (-not (Confirm-Layer "bootstrap" )) {
        Write-Host "Bootstrap not applied. Stop here; no other layers can use a missing state bucket." -ForegroundColor Yellow
        return
    }
    Invoke-Checked "terraform" @("-chdir=$BootstrapDir", "apply", "-input=false", "-no-color", $bootstrapPlan) "Bootstrap apply"

    $newBucket = & terraform "-chdir=$BootstrapDir" "output" "-raw" "terraform_state_bucket_name"
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($newBucket)) {
        Stop-Recovery "Bootstrap applied but Terraform did not return terraform_state_bucket_name."
    }
    $stateBucket = $newBucket.Trim()
    Write-Host "New Terraform state bucket: $stateBucket" -ForegroundColor Green
}

# Check the state bucket protections before using it.
$versioning = & aws s3api get-bucket-versioning --bucket $stateBucket --profile $Profile --region $Region --output json
if ($LASTEXITCODE -ne 0) { Stop-Recovery "Cannot read versioning configuration for $stateBucket." }
if (($versioning | ConvertFrom-Json).Status -ne "Enabled") {
    Stop-Recovery "Terraform state bucket versioning is not enabled. Fix this before proceeding."
}
$publicBlock = & aws s3api get-public-access-block --bucket $stateBucket --profile $Profile --region $Region --output json
if ($LASTEXITCODE -ne 0) { Stop-Recovery "Cannot verify public-access block on $stateBucket." }
$pb = ($publicBlock | ConvertFrom-Json).PublicAccessBlockConfiguration
if (-not ($pb.BlockPublicAcls -and $pb.BlockPublicPolicy -and $pb.IgnorePublicAcls -and $pb.RestrictPublicBuckets)) {
    Stop-Recovery "Terraform state bucket public-access block is incomplete."
}
Write-Host "State bucket protections verified: versioning enabled and all public-access blocks enabled." -ForegroundColor Green

# ----- Shared ECR -----
$ecrStateExists = Test-S3Object $stateBucket "shared/ecr.tfstate"
$existingEcr = Get-ExistingExpectedEcr
if (-not $ecrStateExists -and $existingEcr.Count -gt 0) {
    Stop-Recovery "Shared ECR repositories exist but shared/ecr.tfstate is missing. Recover/import state before applying."
}

Invoke-Checked "terraform" @(
    "-chdir=$EcrDir", "init", "-input=false", "-reconfigure",
    "-backend-config=bucket=$stateBucket",
    "-backend-config=key=shared/ecr.tfstate",
    "-backend-config=region=$Region",
    "-backend-config=encrypt=true",
    "-backend-config=use_lockfile=true"
) "Shared ECR backend initialization"

Invoke-PlanAndMaybeApply -Directory $EcrDir -PlanArgs @(
    "-var=expected_account_id=$ExpectedAccount",
    "-var=aws_region=$Region"
) -PlanFile "ecr-recovery.tfplan" -Layer "Shared ECR" -ConfirmationToken "ecr"

# Verify ECR repositories exist after an apply (or report plan-only).
if ($Apply) {
    $afterEcr = Get-ExistingExpectedEcr
    if ($afterEcr.Count -ne 5) {
        Stop-Recovery "Expected five shared ECR repositories; found $($afterEcr.Count)."
    }
    Write-Host "Verified all five shared ECR repositories." -ForegroundColor Green
}

# ----- Staging AWS foundation -----
if (-not $SkipStaging) {
    $stagingStateExists = Test-S3Object $stateBucket "staging/terraform.tfstate"

    if (-not $stagingStateExists) {
        $clustersText = & aws eks list-clusters --profile $Profile --region $Region --output json
        if ($LASTEXITCODE -ne 0) { Stop-Recovery "Could not inspect EKS clusters; refusing staging plan." }
        $clusters = @((($clustersText | ConvertFrom-Json).clusters))
        $vpcText = & aws ec2 describe-vpcs --filters "Name=cidr-block,Values=10.10.0.0/16" --profile $Profile --region $Region --output json
        if ($LASTEXITCODE -ne 0) { Stop-Recovery "Could not inspect VPCs; refusing staging plan." }
        $vpcExists = @((($vpcText | ConvertFrom-Json).Vpcs)).Count -gt 0
        if ($clusters.Count -gt 0 -or $vpcExists) {
            Stop-Recovery "Staging resources appear to exist but staging/terraform.tfstate is missing. Recover/import state first."
        }
    }

    Invoke-Checked "terraform" @(
        "-chdir=$StagingDir", "init", "-input=false", "-reconfigure",
        "-backend-config=bucket=$stateBucket",
        "-backend-config=key=staging/terraform.tfstate",
        "-backend-config=region=$Region",
        "-backend-config=encrypt=true",
        "-backend-config=use_lockfile=true"
    ) "Staging backend initialization"

    Invoke-PlanAndMaybeApply -Directory $StagingDir -PlanArgs @(
        "-var-file=staging.tfvars"
    ) -PlanFile "staging-recovery.tfplan" -Layer "Staging" -ConfirmationToken "staging"

    if ($Apply) {
        $clusterList = & aws eks list-clusters --profile $Profile --region $Region --output json
        if ($LASTEXITCODE -ne 0) { Stop-Recovery "Could not verify EKS cluster list." }
        Write-Host "EKS clusters in $Region:"
        ($clusterList | ConvertFrom-Json).clusters | ForEach-Object { Write-Host " - $_" }
        Write-Host "Check node groups/add-ons and Kubernetes readiness separately with AWS CLI and kubectl."
    }
}

Write-Host "`nRecovery sequence finished." -ForegroundColor Green
Write-Host "Scope restored/planned: bootstrap state bucket, shared ECR, staging Terraform resources."
Write-Host "Not included: application image builds, Kubernetes Helm/app deployment, Atlas, Cloudflare/ACM DNS validation, Jenkins EC2, Ansible execution, monitoring, and secret VALUE restoration."
Write-Host "Never delete the Terraform state bucket or its versioned state objects."
'''
path = Path("/mnt/data/rebuild-aws-complete.ps1")
path.write_text(script, encoding="utf-8")
print(f"Created {path} ({path.stat().st_size} bytes)")

  - Do not delete the Terraform state bucket or its state objects.
  - If remote Terraform state was lost, stop and recover/import state before
    applying environment roots. Do not blindly create resources against an
    empty state; name conflicts and duplicate resources can result.
  - This script creates infrastructure; it does not stop or terminate it.
EOF
