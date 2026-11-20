[CmdletBinding()]
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
    $result = & aws s3api list-objects-v2 `
        --bucket $Bucket `
        --prefix $Key `
        --max-keys 1 `
        --profile $Profile `
        --region $Region `
        --output json 2>&1

    if ($LASTEXITCODE -ne 0) {
        Stop-Recovery "Unable to check S3 state object $Key. AWS response: $result"
    }

    $data = ($result | Out-String) | ConvertFrom-Json

    return (@($data.Contents | Where-Object { $_.Key -ceq $Key }).Count -gt 0)
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
        Write-Host "EKS clusters in ${Region}:"
        ($clusterList | ConvertFrom-Json).clusters | ForEach-Object { Write-Host " - $_" }
        Write-Host "Check node groups/add-ons and Kubernetes readiness separately with AWS CLI and kubectl."
    }
}

Write-Host "`nRecovery sequence finished." -ForegroundColor Green
Write-Host "Scope restored/planned: bootstrap state bucket, shared ECR, staging Terraform resources."
Write-Host "Not included: application image builds, Kubernetes Helm/app deployment, Atlas, Cloudflare/ACM DNS validation, Jenkins EC2, Ansible execution, monitoring, and secret VALUE restoration."
Write-Host "Never delete the Terraform state bucket or its versioned state objects."
