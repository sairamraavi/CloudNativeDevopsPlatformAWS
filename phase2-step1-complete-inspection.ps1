#requires -Version 5.1
<#
PHASE 2 / STEP 1 — COMPLETE READ-ONLY INSPECTION
Account: 529976312668
Fixed AWS region: ap-southeast-2 (Sydney)
Profile: personal

This script does NOT create, update, stop, start, or delete AWS resources.
It does NOT retrieve secret values, SSM parameter values, object contents,
database contents, private keys, or Terraform state contents.

Run from the repository root (recommended), or pass -RepositoryRoot.
AWS CLI v2 and an already-authenticated profile are required.
#>
[CmdletBinding()]
param(
    [string]$Profile = "personal",
    [string]$ExpectedAccount = "529976312668",
    [string]$Region = "ap-southeast-2",
    [string]$RepositoryRoot = $PSScriptRoot,
    [string]$OutputRoot = ""
)

$ErrorActionPreference = "Stop"
$env:AWS_PAGER = ""
$env:AWS_CLI_AUTO_PROMPT = "off"
$env:AWS_DEFAULT_REGION = $Region
$env:AWS_REGION = $Region

if ($Region -ne "ap-southeast-2") { throw "This inspection is locked to ap-southeast-2 (Sydney). Do not change the project region." }
if ([string]::IsNullOrWhiteSpace($OutputRoot)) { $OutputRoot = Join-Path $PSScriptRoot "Phase2-Step1-Inspection" }
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$outDir = Join-Path $OutputRoot $stamp
$rawDir = Join-Path $outDir "raw"
New-Item -ItemType Directory -Force -Path $rawDir | Out-Null

$script:Checks = [System.Collections.Generic.List[object]]::new()
$script:Failures = [System.Collections.Generic.List[object]]::new()
$script:Notes = [System.Collections.Generic.List[string]]::new()

function Add-Note([string]$Text) {
    $script:Notes.Add($Text)
    Write-Host $Text
}

function Invoke-AwsRead {
    param(
        [Parameter(Mandatory=$true)][string]$Label,
        [Parameter(Mandatory=$true)][string[]]$CliArgs,
        [string]$CallRegion = $Region,
        [switch]$GlobalCall
    )
    $scope = if ($GlobalCall) { "global" } else { $CallRegion }
    $safe = (($scope + "__" + $Label) -replace '[^A-Za-z0-9._-]','_')
    $file = Join-Path $rawDir ($safe + ".json")
    $argv = @($CliArgs) + @("--profile",$Profile,"--no-cli-pager","--output","json")
    if (-not $GlobalCall -and $CallRegion) { $argv += @("--region",$CallRegion) }

    $oldEap = $ErrorActionPreference
    $nativePrefExists = $null -ne (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue)
    $oldNative = $null
    if ($nativePrefExists) { $oldNative = $PSNativeCommandUseErrorActionPreference }
    try {
        if ($nativePrefExists) { $PSNativeCommandUseErrorActionPreference = $false }
        $ErrorActionPreference = "Continue"
        $output = & aws @argv 2>&1
        $exitCode = $LASTEXITCODE
        $ErrorActionPreference = $oldEap
    } catch {
        $exitCode = 1
        $output = @($_.Exception.Message)
        $ErrorActionPreference = $oldEap
    } finally {
        if ($nativePrefExists) { $PSNativeCommandUseErrorActionPreference = $oldNative }
        $ErrorActionPreference = $oldEap
    }

    $text = (@($output) | ForEach-Object { "$_" }) -join "`n"
    Set-Content -LiteralPath $file -Value $text -Encoding UTF8

    $status = if ($exitCode -eq 0) { "SUCCESS" } else { "BLOCKED_OR_FAILED" }
    $count = ""
    if ($exitCode -eq 0 -and $text.Trim()) {
        try {
            $obj = $text | ConvertFrom-Json
            foreach ($p in $obj.PSObject.Properties) {
                if ($p.Value -is [array]) { $count = $p.Value.Count; break }
            }
        } catch {}
    }
    $errorText = ""
    if ($exitCode -ne 0) {
        $flat = ($text -replace "`r?`n"," ").Trim()
        $errorText = $flat.Substring(0,[Math]::Min(1200,$flat.Length))
        $script:Failures.Add([pscustomobject]@{Scope=$scope;Check=$Label;ExitCode=$exitCode;Error=$errorText;RawFile=$file})
    }
    $script:Checks.Add([pscustomobject]@{Scope=$scope;Check=$Label;Status=$status;Count=$count;ExitCode=$exitCode;RawFile=$file;Error=$errorText})
    return [pscustomobject]@{ExitCode=$exitCode;Text=$text;File=$file}
}

function Read-JsonFile([string]$Path) {
    if (Test-Path -LiteralPath $Path) {
        try { return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json) } catch {}
    }
    return $null
}

function Invoke-ChildFromArray {
    param([string]$SourceFile,[string]$Property,[string]$ChildLabel,[string[]]$PrefixArgs,[string]$IdProperty)
    $o = Read-JsonFile $SourceFile
    if ($null -eq $o) { return }
    foreach ($item in @($o.$Property)) {
        $id = [string]$item.$IdProperty
        if ([string]::IsNullOrWhiteSpace($id)) { continue }
        $safe = $id -replace '[^A-Za-z0-9._-]','_'
        $null = Invoke-AwsRead -Label "$ChildLabel-$safe" -CliArgs ($PrefixArgs + @($id))
    }
}

Write-Host "`nPHASE 2 — STEP 1: READ-ONLY INSPECTION"
Write-Host "Account expected: $ExpectedAccount | Region locked: $Region | Profile: $Profile"
Write-Host "Repository root: $RepositoryRoot"
Write-Host "Output: $outDir"
if (-not (Get-Command aws -ErrorAction SilentlyContinue)) { throw "AWS CLI not found. Install AWS CLI v2." }

# 1. Identity and region guard.
$identityCall = Invoke-AwsRead -Label "caller-identity" -CliArgs @("sts","get-caller-identity")
if ($identityCall.ExitCode -ne 0) { throw "AWS identity check failed. Authenticate with aws login --profile $Profile, then rerun." }
$identity = $identityCall.Text | ConvertFrom-Json
if ($identity.Account -ne $ExpectedAccount) { throw "Wrong account. Expected $ExpectedAccount; got $($identity.Account). Stopping." }
Add-Note "Verified caller: $($identity.Arn)"
$null = Invoke-AwsRead -Label "region-opt-in-status" -CliArgs @("ec2","describe-regions","--region-names",$Region,"--all-regions")

# 2. Billing and commitments. Cost Explorer is a global billing API hosted in us-east-1.
$today = (Get-Date).ToString("yyyy-MM-dd")
$monthStart = (Get-Date -Day 1).ToString("yyyy-MM-dd")
$thirtyDaysAgo = (Get-Date).AddDays(-30).ToString("yyyy-MM-dd")
$nextMonth = (Get-Date -Day 1).AddMonths(1).ToString("yyyy-MM-dd")
Add-Note "`n[1/8] BILLING / COST / COMMITMENTS"
$null = Invoke-AwsRead -Label "cost-mtd-total-unblended-amortized" -CallRegion "us-east-1" -CliArgs @("ce","get-cost-and-usage","--time-period","Start=$monthStart,End=$today","--granularity","MONTHLY","--metrics","UnblendedCost","AmortizedCost","NetUnblendedCost")
$null = Invoke-AwsRead -Label "cost-mtd-service-region-unblended-amortized" -CallRegion "us-east-1" -CliArgs @("ce","get-cost-and-usage","--time-period","Start=$monthStart,End=$today","--granularity","MONTHLY","--metrics","UnblendedCost","AmortizedCost","NetUnblendedCost","--group-by","Type=DIMENSION,Key=SERVICE","Type=DIMENSION,Key=REGION")
$null = Invoke-AwsRead -Label "cost-last-30-days-daily-service" -CallRegion "us-east-1" -CliArgs @("ce","get-cost-and-usage","--time-period","Start=$thirtyDaysAgo,End=$today","--granularity","DAILY","--metrics","UnblendedCost","AmortizedCost")
$null = Invoke-AwsRead -Label "cost-forecast-month" -CallRegion "us-east-1" -CliArgs @("ce","get-cost-forecast","--time-period","Start=$today,End=$nextMonth","--metric","UNBLENDED_COST","--granularity","MONTHLY")
$null = Invoke-AwsRead -Label "cost-anomaly-monitors" -CallRegion "us-east-1" -CliArgs @("ce","get-anomaly-monitors")
$null = Invoke-AwsRead -Label "cost-anomalies-current-month" -CallRegion "us-east-1" -CliArgs @("ce","get-anomalies","--date-interval","StartDate=$monthStart,EndDate=$today")
$null = Invoke-AwsRead -Label "reservation-utilization" -CallRegion "us-east-1" -CliArgs @("ce","get-reservation-utilization","--time-period","Start=$thirtyDaysAgo,End=$today")
$null = Invoke-AwsRead -Label "reservation-coverage" -CallRegion "us-east-1" -CliArgs @("ce","get-reservation-coverage","--time-period","Start=$thirtyDaysAgo,End=$today")
$null = Invoke-AwsRead -Label "savings-plans-utilization" -CallRegion "us-east-1" -CliArgs @("ce","get-savings-plans-utilization","--time-period","Start=$thirtyDaysAgo,End=$today")
$null = Invoke-AwsRead -Label "savings-plans-coverage" -CallRegion "us-east-1" -CliArgs @("ce","get-savings-plans-coverage","--time-period","Start=$thirtyDaysAgo,End=$today")
$null = Invoke-AwsRead -Label "budgets" -CallRegion "us-east-1" -CliArgs @("budgets","describe-budgets","--account-id",$ExpectedAccount)
$null = Invoke-AwsRead -Label "ec2-reserved-instances" -CliArgs @("ec2","describe-reserved-instances")
$null = Invoke-AwsRead -Label "savings-plans" -CallRegion "us-east-1" -CliArgs @("savingsplans","describe-savings-plans")

# 3. Core infrastructure and all common cost-bearing services in the fixed region.
Add-Note "`n[2/8] CORE REGIONAL INFRASTRUCTURE — $Region"
$regionalChecks = @(
    @{N="ec2-instances-all-states";A=@("ec2","describe-instances")},
    @{N="ec2-instance-status";A=@("ec2","describe-instance-status","--include-all-instances")},
    @{N="ec2-launch-templates";A=@("ec2","describe-launch-templates")},
    @{N="ec2-images-owned";A=@("ec2","describe-images","--owners","self")},
    @{N="ebs-volumes";A=@("ec2","describe-volumes")},
    @{N="ebs-snapshots-owned";A=@("ec2","describe-snapshots","--owner-ids","self")},
    @{N="ebs-fast-snapshot-restores";A=@("ec2","describe-fast-snapshot-restores")},
    @{N="ebs-encryption-default";A=@("ec2","get-ebs-encryption-by-default")},
    @{N="ebs-default-kms-key";A=@("ec2","get-ebs-default-kms-key-id")},
    @{N="vpcs";A=@("ec2","describe-vpcs")},
    @{N="subnets";A=@("ec2","describe-subnets")},
    @{N="route-tables";A=@("ec2","describe-route-tables")},
    @{N="internet-gateways";A=@("ec2","describe-internet-gateways")},
    @{N="nat-gateways";A=@("ec2","describe-nat-gateways")},
    @{N="elastic-ips";A=@("ec2","describe-addresses")},
    @{N="security-groups";A=@("ec2","describe-security-groups")},
    @{N="network-acls";A=@("ec2","describe-network-acls")},
    @{N="network-interfaces";A=@("ec2","describe-network-interfaces")},
    @{N="vpc-endpoints";A=@("ec2","describe-vpc-endpoints")},
    @{N="vpc-flow-logs";A=@("ec2","describe-flow-logs")},
    @{N="transit-gateways";A=@("ec2","describe-transit-gateways")},
    @{N="vpc-peering";A=@("ec2","describe-vpc-peering-connections")},
    @{N="transit-gateway-attachments";A=@("ec2","describe-transit-gateway-attachments")},
    @{N="key-pairs";A=@("ec2","describe-key-pairs")},
    @{N="placement-groups";A=@("ec2","describe-placement-groups")},
    @{N="autoscaling-groups";A=@("autoscaling","describe-auto-scaling-groups")},
    @{N="autoscaling-launch-configurations";A=@("autoscaling","describe-launch-configurations")},
    @{N="eks-clusters";A=@("eks","list-clusters")},
    @{N="elbv2-load-balancers";A=@("elbv2","describe-load-balancers")},
    @{N="elbv2-target-groups";A=@("elbv2","describe-target-groups")},
    @{N="classic-load-balancers";A=@("elb","describe-load-balancers")},
    @{N="rds-instances";A=@("rds","describe-db-instances")},
    @{N="rds-clusters";A=@("rds","describe-db-clusters")},
    @{N="rds-instance-snapshots";A=@("rds","describe-db-snapshots")},
    @{N="rds-cluster-snapshots";A=@("rds","describe-db-cluster-snapshots")},
    @{N="rds-proxies";A=@("rds","describe-db-proxies")},
    @{N="rds-reserved-instances";A=@("rds","describe-reserved-db-instances")},
    @{N="efs-file-systems";A=@("efs","describe-file-systems")},
    @{N="fsx-file-systems";A=@("fsx","describe-file-systems")},
    @{N="lambda-functions";A=@("lambda","list-functions")},
    @{N="lambda-event-source-mappings";A=@("lambda","list-event-source-mappings")},
    @{N="ecs-clusters";A=@("ecs","list-clusters")},
    @{N="dynamodb-tables";A=@("dynamodb","list-tables")},
    @{N="dynamodb-backups";A=@("dynamodb","list-backups")},
    @{N="elasticache-clusters";A=@("elasticache","describe-cache-clusters","--show-cache-node-info")},
    @{N="elasticache-replication-groups";A=@("elasticache","describe-replication-groups")},
    @{N="opensearch-domains";A=@("opensearch","list-domain-names")},
    @{N="redshift-clusters";A=@("redshift","describe-clusters")},
    @{N="redshift-serverless";A=@("redshift-serverless","list-workgroups")},
    @{N="sagemaker-endpoints";A=@("sagemaker","list-endpoints")},
    @{N="sagemaker-notebook-instances";A=@("sagemaker","list-notebook-instances")},
    @{N="batch-compute-environments";A=@("batch","describe-compute-environments")},
    @{N="app-runner-services";A=@("apprunner","list-services")},
    @{N="glue-jobs";A=@("glue","get-jobs")},
    @{N="glue-crawlers";A=@("glue","get-crawlers")},
    @{N="athena-workgroups";A=@("athena","list-work-groups")},
    @{N="kinesis-streams";A=@("kinesis","list-streams")},
    @{N="msk-clusters";A=@("kafka","list-clusters-v2")},
    @{N="step-functions";A=@("stepfunctions","list-state-machines")},
    @{N="api-gateway-rest";A=@("apigateway","get-rest-apis")},
    @{N="api-gateway-v2";A=@("apigatewayv2","get-apis")},
    @{N="cognito-user-pools";A=@("cognito-idp","list-user-pools","--max-results","60")},
    @{N="backup-vaults";A=@("backup","list-backup-vaults")},
    @{N="backup-plans";A=@("backup","list-backup-plans")},
    @{N="backup-jobs";A=@("backup","list-backup-jobs","--by-created-after",$((Get-Date).AddDays(-90).ToUniversalTime().ToString("o")))},
    @{N="cloudformation-stacks";A=@("cloudformation","list-stacks","--stack-status-filter","CREATE_COMPLETE","UPDATE_COMPLETE","UPDATE_ROLLBACK_COMPLETE")},
    @{N="codebuild-projects";A=@("codebuild","list-projects")},
    @{N="codepipeline-pipelines";A=@("codepipeline","list-pipelines")},
    @{N="codedeploy-applications";A=@("codedeploy","list-applications")},
    @{N="codeartifact-domains";A=@("codeartifact","list-domains")},
    @{N="amplify-apps";A=@("amplify","list-apps")},
    @{N="ses-identities";A=@("sesv2","list-email-identities")},
    @{N="ses-configuration-sets";A=@("sesv2","list-configuration-sets")},
    @{N="acm-certificates";A=@("acm","list-certificates")},
    @{N="secrets-metadata";A=@("secretsmanager","list-secrets")},
    @{N="ssm-managed-instances";A=@("ssm","describe-instance-information")},
    @{N="ssm-parameters-metadata";A=@("ssm","describe-parameters")},
    @{N="ssm-maintenance-windows";A=@("ssm","describe-maintenance-windows")},
    @{N="kms-keys";A=@("kms","list-keys")},
    @{N="cloudwatch-log-groups";A=@("logs","describe-log-groups")},
    @{N="cloudwatch-alarms";A=@("cloudwatch","describe-alarms")},
    @{N="cloudwatch-dashboards";A=@("cloudwatch","list-dashboards")},
    @{N="sns-topics";A=@("sns","list-topics")},
    @{N="sqs-queues";A=@("sqs","list-queues")},
    @{N="eventbridge-buses";A=@("events","list-event-buses")},
    @{N="eventbridge-rules-default";A=@("events","list-rules")},
    @{N="resource-groups";A=@("resource-groups","list-groups")},
    @{N="resource-explorer-index";A=@("resource-explorer-2","list-indexes")},
    @{N="config-recorders";A=@("configservice","describe-configuration-recorders")},
    @{N="config-recorder-status";A=@("configservice","describe-configuration-recorder-status")},
    @{N="config-delivery-channels";A=@("configservice","describe-delivery-channels")},
    @{N="config-rules";A=@("configservice","describe-config-rules")},
    @{N="config-compliance-summary";A=@("configservice","get-compliance-summary-by-config-rule")},
    @{N="cloudtrail-trails";A=@("cloudtrail","describe-trails","--include-shadow-trails")},
    @{N="cloudtrail-event-data-stores";A=@("cloudtrail","list-event-data-stores")},
    @{N="guardduty-detectors";A=@("guardduty","list-detectors")},
    @{N="securityhub-status";A=@("securityhub","describe-hub")},
    @{N="inspector-account-status";A=@("inspector2","batch-get-account-status","--account-ids",$ExpectedAccount)},
    @{N="macie-session";A=@("macie2","get-macie-session")},
    @{N="access-analyzers";A=@("accessanalyzer","list-analyzers")},
    @{N="waf-v2-web-acls";A=@("wafv2","list-web-acls","--scope","REGIONAL")},
    @{N="waf-classic-web-acls";A=@("waf","list-web-acls")}
)
foreach ($c in $regionalChecks) {
    $cli = @($c.A)
    $null = Invoke-AwsRead -Label $c.N -CliArgs $cli
}

# 4. Expand child resources for EKS, ECR, KMS, secrets, IAM and logging.
Add-Note "`n[3/8] CHILD RESOURCE / SECURITY CONFIGURATION DETAILS"
$eksFile = Join-Path $rawDir "$Region`__eks-clusters.json"
$eksObj = Read-JsonFile $eksFile
if ($eksObj) {
    foreach ($cluster in @($eksObj.clusters)) {
        $null = Invoke-AwsRead -Label ("eks-cluster-" + $cluster + "-describe") -CliArgs @("eks","describe-cluster","--name",$cluster)
        $ngCall = Invoke-AwsRead -Label ("eks-cluster-" + $cluster + "-nodegroups") -CliArgs @("eks","list-nodegroups","--cluster-name",$cluster)
        $null = Invoke-AwsRead -Label ("eks-cluster-" + $cluster + "-addons") -CliArgs @("eks","list-addons","--cluster-name",$cluster)
        $null = Invoke-AwsRead -Label ("eks-cluster-" + $cluster + "-fargate-profiles") -CliArgs @("eks","list-fargate-profiles","--cluster-name",$cluster)
        $null = Invoke-AwsRead -Label ("eks-cluster-" + $cluster + "-access-entries") -CliArgs @("eks","list-access-entries","--cluster-name",$cluster)
        if ($ngCall.ExitCode -eq 0) {
            $ngObj = $ngCall.Text | ConvertFrom-Json
            foreach ($ng in @($ngObj.nodegroups)) {
                $null = Invoke-AwsRead -Label ("eks-nodegroup-" + $cluster + "-" + $ng) -CliArgs @("eks","describe-nodegroup","--cluster-name",$cluster,"--nodegroup-name",$ng)
            }
        }
        $addonFile = Join-Path $rawDir (($Region + "__eks-cluster-" + $cluster + "-addons.json") -replace '[^A-Za-z0-9._-]','_')
        $addonObj = Read-JsonFile $addonFile
        if ($addonObj) {
            foreach ($addon in @($addonObj.addons)) {
                $null = Invoke-AwsRead -Label ("eks-addon-" + $cluster + "-" + $addon) -CliArgs @("eks","describe-addon","--cluster-name",$cluster,"--addon-name",$addon)
            }
        }
    }
}

$ecrFile = Join-Path $rawDir "$Region`__ecr-repositories.json"
# Regional base query is named ecr-repositories in this report.
$null = Invoke-AwsRead -Label "ecr-repositories" -CliArgs @("ecr","describe-repositories")
$ecrObj = Read-JsonFile (Join-Path $rawDir "$Region`__ecr-repositories.json")
if ($ecrObj) {
    foreach ($repo in @($ecrObj.repositories)) {
        $rn = $repo.repositoryName
        $safe = $rn -replace '[^A-Za-z0-9._-]','_'
        $null = Invoke-AwsRead -Label "ecr-images-$safe" -CliArgs @("ecr","describe-images","--repository-name",$rn)
        $null = Invoke-AwsRead -Label "ecr-lifecycle-$safe" -CliArgs @("ecr","get-lifecycle-policy","--repository-name",$rn)
        $null = Invoke-AwsRead -Label "ecr-policy-$safe" -CliArgs @("ecr","get-repository-policy","--repository-name",$rn)
        $null = Invoke-AwsRead -Label "ecr-scanning-$safe" -CliArgs @("ecr","get-registry-scanning-configuration")
    }
}

$acmObj = Read-JsonFile (Join-Path $rawDir "$Region`__acm-certificates.json")
if ($acmObj) {
    foreach ($cert in @($acmObj.CertificateSummaryList)) {
        if ($cert.CertificateArn) {
            $certSafe = $cert.DomainName -replace '[^A-Za-z0-9._-]','_'
            $null = Invoke-AwsRead -Label "acm-certificate-$certSafe" -CliArgs @("acm","describe-certificate","--certificate-arn",$cert.CertificateArn)
        }
    }
}
$kmsObj = Read-JsonFile (Join-Path $rawDir "$Region`__kms-keys.json")
if ($kmsObj) {
    foreach ($k in @($kmsObj.Keys)) {
        $kid = $k.KeyId
        $safe = $kid -replace '[^A-Za-z0-9._-]','_'
        $null = Invoke-AwsRead -Label "kms-key-$safe-describe" -CliArgs @("kms","describe-key","--key-id",$kid)
        $null = Invoke-AwsRead -Label "kms-key-$safe-rotation" -CliArgs @("kms","get-key-rotation-status","--key-id",$kid)
        $null = Invoke-AwsRead -Label "kms-key-$safe-aliases" -CliArgs @("kms","list-aliases","--key-id",$kid)
        $null = Invoke-AwsRead -Label "kms-key-$safe-grants" -CliArgs @("kms","list-grants","--key-id",$kid)
        $null = Invoke-AwsRead -Label "kms-key-$safe-policy" -CliArgs @("kms","get-key-policy","--key-id",$kid,"--policy-name","default")
    }
}
$null = Invoke-AwsRead -Label "kms-aliases" -CliArgs @("kms","list-aliases")

$secretObj = Read-JsonFile (Join-Path $rawDir "$Region`__secrets-metadata.json")
if ($secretObj) {
    foreach ($s in @($secretObj.SecretList)) {
        if ($s.Name -match "streamingapp|capstone") {
            $safe = $s.Name -replace '[^A-Za-z0-9._-]','_'
            $null = Invoke-AwsRead -Label "secret-$safe-description" -CliArgs @("secretsmanager","describe-secret","--secret-id",$s.ARN)
            $null = Invoke-AwsRead -Label "secret-$safe-version-metadata" -CliArgs @("secretsmanager","list-secret-version-ids","--secret-id",$s.ARN)
        }
    }
}

# IAM global inventory, project role details and access-key metadata only.
$null = Invoke-AwsRead -Label "iam-account-summary" -GlobalCall -CliArgs @("iam","get-account-summary")
$null = Invoke-AwsRead -Label "iam-account-password-policy" -GlobalCall -CliArgs @("iam","get-account-password-policy")
$null = Invoke-AwsRead -Label "iam-roles" -GlobalCall -CliArgs @("iam","list-roles")
$null = Invoke-AwsRead -Label "iam-instance-profiles" -GlobalCall -CliArgs @("iam","list-instance-profiles")
$null = Invoke-AwsRead -Label "iam-oidc-providers" -GlobalCall -CliArgs @("iam","list-open-id-connect-providers")
$null = Invoke-AwsRead -Label "iam-local-policies" -GlobalCall -CliArgs @("iam","list-policies","--scope","Local")
$null = Invoke-AwsRead -Label "iam-users-metadata" -GlobalCall -CliArgs @("iam","list-users")
$null = Invoke-AwsRead -Label "iam-access-analyzers-global" -GlobalCall -CliArgs @("accessanalyzer","list-analyzers","--type","ACCOUNT")
$oidcObj = Read-JsonFile (Join-Path $rawDir "global__iam-oidc-providers.json")
if ($oidcObj) {
    foreach ($provider in @($oidcObj.OpenIDConnectProviderList)) {
        $providerArn = $provider.Arn
        $providerSafe = $providerArn -replace '[^A-Za-z0-9._-]','_'
        $null = Invoke-AwsRead -Label "iam-oidc-provider-$providerSafe" -GlobalCall -CliArgs @("iam","get-open-id-connect-provider","--open-id-connect-provider-arn",$providerArn)
    }
}
$iamRoles = Read-JsonFile (Join-Path $rawDir "global__iam-roles.json")
if ($iamRoles) {
    foreach ($role in @($iamRoles.Roles)) {
        if ($role.RoleName -match "streamingapp|capstone|jenkins|eks|AWSServiceRole") {
            $rn = $role.RoleName
            $safe = $rn -replace '[^A-Za-z0-9._-]','_'
            $null = Invoke-AwsRead -Label "iam-role-$safe-attached-policies" -GlobalCall -CliArgs @("iam","list-attached-role-policies","--role-name",$rn)
            $null = Invoke-AwsRead -Label "iam-role-$safe-inline-policies" -GlobalCall -CliArgs @("iam","list-role-policies","--role-name",$rn)
            $null = Invoke-AwsRead -Label "iam-role-$safe-instance-profiles" -GlobalCall -CliArgs @("iam","list-instance-profiles-for-role","--role-name",$rn)

            $attachedFile = Join-Path $rawDir ("global__iam-role-" + $safe + "-attached-policies.json")
            $attachedObj = Read-JsonFile $attachedFile
            if ($attachedObj) {
                foreach ($pol in @($attachedObj.AttachedPolicies)) {
                    $policyArn = $pol.PolicyArn
                    $polSafe = $pol.PolicyName -replace '[^A-Za-z0-9._-]','_'
                    $metaCall = Invoke-AwsRead -Label "iam-role-$safe-managed-policy-$polSafe-meta" -GlobalCall -CliArgs @("iam","get-policy","--policy-arn",$policyArn)
                    if ($metaCall.ExitCode -eq 0) {
                        $meta = $metaCall.Text | ConvertFrom-Json
                        $version = $meta.Policy.DefaultVersionId
                        if ($version) { $null = Invoke-AwsRead -Label "iam-role-$safe-managed-policy-$polSafe-document" -GlobalCall -CliArgs @("iam","get-policy-version","--policy-arn",$policyArn,"--version-id",$version) }
                    }
                }
            }
            $inlineFile = Join-Path $rawDir ("global__iam-role-" + $safe + "-inline-policies.json")
            $inlineObj = Read-JsonFile $inlineFile
            if ($inlineObj) {
                foreach ($policyName in @($inlineObj.PolicyNames)) {
                    $inlineSafe = $policyName -replace '[^A-Za-z0-9._-]','_'
                    $null = Invoke-AwsRead -Label "iam-role-$safe-inline-$inlineSafe-document" -GlobalCall -CliArgs @("iam","get-role-policy","--role-name",$rn,"--policy-name",$policyName)
                }
            }
        }
    }
}
$iamUsers = Read-JsonFile (Join-Path $rawDir "global__iam-users-metadata.json")
if ($iamUsers) {
    foreach ($u in @($iamUsers.Users)) {
        $null = Invoke-AwsRead -Label ("iam-user-" + $u.UserName + "-access-key-metadata") -GlobalCall -CliArgs @("iam","list-access-keys","--user-name",$u.UserName)
    }
}

# 5. Global services and every S3 bucket's configuration (no object contents).
Add-Note "`n[4/8] GLOBAL SERVICES / S3 / DNS / CDN"
$null = Invoke-AwsRead -Label "s3-buckets" -GlobalCall -CliArgs @("s3api","list-buckets")
$null = Invoke-AwsRead -Label "cloudfront-distributions" -CallRegion "us-east-1" -CliArgs @("cloudfront","list-distributions")
$null = Invoke-AwsRead -Label "route53-hosted-zones" -GlobalCall -CliArgs @("route53","list-hosted-zones")
$null = Invoke-AwsRead -Label "route53-health-checks" -GlobalCall -CliArgs @("route53","list-health-checks")
$null = Invoke-AwsRead -Label "route53-query-logging" -GlobalCall -CliArgs @("route53","list-query-logging-configs")
$null = Invoke-AwsRead -Label "organizations-account" -GlobalCall -CliArgs @("organizations","describe-organization")
$null = Invoke-AwsRead -Label "organizations-effective-policy-backup" -GlobalCall -CliArgs @("organizations","describe-effective-policy","--policy-type","BACKUP_POLICY","--target-id",$ExpectedAccount)
$null = Invoke-AwsRead -Label "organizations-effective-policy-tag" -GlobalCall -CliArgs @("organizations","describe-effective-policy","--policy-type","TAG_POLICY","--target-id",$ExpectedAccount)
$null = Invoke-AwsRead -Label "organizations-scp-policies-for-account" -GlobalCall -CliArgs @("organizations","list-policies-for-target","--target-id",$ExpectedAccount,"--filter","SERVICE_CONTROL_POLICY")

$s3Obj = Read-JsonFile (Join-Path $rawDir "global__s3-buckets.json")
if ($s3Obj) {
    foreach ($b in @($s3Obj.Buckets)) {
        $bn = $b.Name
        $safe = $bn -replace '[^A-Za-z0-9._-]','_'
        $null = Invoke-AwsRead -Label "s3-$safe-location" -GlobalCall -CliArgs @("s3api","get-bucket-location","--bucket",$bn)
        foreach ($entry in @(
            @("versioning","get-bucket-versioning"),
            @("encryption","get-bucket-encryption"),
            @("public-access-block","get-public-access-block"),
            @("ownership","get-bucket-ownership-controls"),
            @("lifecycle","get-bucket-lifecycle-configuration"),
            @("logging","get-bucket-logging"),
            @("policy-status","get-bucket-policy-status"),
            @("policy","get-bucket-policy"),
            @("tagging","get-bucket-tagging"),
            @("cors","get-bucket-cors"),
            @("object-lock","get-object-lock-configuration")
        )) {
            $null = Invoke-AwsRead -Label "s3-$safe-$($entry[0])" -GlobalCall -CliArgs @("s3api",$entry[1],"--bucket",$bn)
        }
        if ($bn -eq "streamingapp-tfstate-8a4b578417838a617bba947a4f" -or $bn -match "tfstate|terraform") {
            $null = Invoke-AwsRead -Label "s3-$safe-state-objects-metadata" -GlobalCall -CliArgs @("s3api","list-objects-v2","--bucket",$bn,"--max-keys","1000")
            $null = Invoke-AwsRead -Label "s3-$safe-state-object-versions-metadata" -GlobalCall -CliArgs @("s3api","list-object-versions","--bucket",$bn,"--max-keys","1000")
        }
    }
}

$snsObj = Read-JsonFile (Join-Path $rawDir "$Region`__sns-topics.json")
if ($snsObj) {
    foreach ($topic in @($snsObj.Topics)) {
        $arn = $topic.TopicArn
        $safeTopic = ($arn -split ':')[-1] -replace '[^A-Za-z0-9._-]','_'
        $null = Invoke-AwsRead -Label "sns-$safeTopic-attributes" -CliArgs @("sns","get-topic-attributes","--topic-arn",$arn)
        $null = Invoke-AwsRead -Label "sns-$safeTopic-subscriptions" -CliArgs @("sns","list-subscriptions-by-topic","--topic-arn",$arn)
    }
}
$sqsObj = Read-JsonFile (Join-Path $rawDir "$Region`__sqs-queues.json")
if ($sqsObj) {
    foreach ($queueUrl in @($sqsObj.QueueUrls)) {
        $safeQueue = ($queueUrl -split '/')[-1] -replace '[^A-Za-z0-9._-]','_'
        $null = Invoke-AwsRead -Label "sqs-$safeQueue-attributes" -CliArgs @("sqs","get-queue-attributes","--queue-url",$queueUrl,"--attribute-names","All")
    }
}

# 6. Security, governance, audit trails, backup and account posture.
Add-Note "`n[5/8] SECURITY / GOVERNANCE / AUDIT / BACKUP"
$null = Invoke-AwsRead -Label "cloudtrail-trails" -CliArgs @("cloudtrail","describe-trails","--include-shadow-trails")
$null = Invoke-AwsRead -Label "cloudtrail-event-data-stores" -CliArgs @("cloudtrail","list-event-data-stores")
$null = Invoke-AwsRead -Label "guardduty-detectors" -CliArgs @("guardduty","list-detectors")
$null = Invoke-AwsRead -Label "securityhub-hub" -CliArgs @("securityhub","describe-hub")
$null = Invoke-AwsRead -Label "inspector-account-status" -CliArgs @("inspector2","batch-get-account-status","--account-ids",$ExpectedAccount)
$null = Invoke-AwsRead -Label "macie-session" -CliArgs @("macie2","get-macie-session")
$null = Invoke-AwsRead -Label "access-analyzers-regional" -CliArgs @("accessanalyzer","list-analyzers")
$null = Invoke-AwsRead -Label "waf-regional-acls" -CliArgs @("wafv2","list-web-acls","--scope","REGIONAL")
$null = Invoke-AwsRead -Label "backup-report-plans" -CliArgs @("backup","list-report-plans")
$null = Invoke-AwsRead -Label "backup-frameworks" -CliArgs @("backup","list-frameworks")
$backupVaults = Read-JsonFile (Join-Path $rawDir "$Region`__backup-vaults.json")
if ($backupVaults) {
    foreach ($vault in @($backupVaults.BackupVaultList)) {
        if ($vault.BackupVaultName) {
            $vSafe = $vault.BackupVaultName -replace '[^A-Za-z0-9._-]','_'
            $null = Invoke-AwsRead -Label "backup-vault-$vSafe-recovery-points" -CliArgs @("backup","list-recovery-points-by-backup-vault","--backup-vault-name",$vault.BackupVaultName)
            $null = Invoke-AwsRead -Label "backup-vault-$vSafe-access-policy" -CliArgs @("backup","get-backup-vault-access-policy","--backup-vault-name",$vault.BackupVaultName)
        }
    }
}
$configRules = Read-JsonFile (Join-Path $rawDir "$Region`__config-rules.json")
if ($configRules) {
    foreach ($rule in @($configRules.ConfigRules)) {
        if ($rule.ConfigRuleName) {
            $rSafe = $rule.ConfigRuleName -replace '[^A-Za-z0-9._-]','_'
            $null = Invoke-AwsRead -Label "config-rule-$rSafe-compliance" -CliArgs @("configservice","get-compliance-details-by-config-rule","--config-rule-name",$rule.ConfigRuleName)
        }
    }
}
$null = Invoke-AwsRead -Label "service-quotas-eks" -CliArgs @("service-quotas","list-service-quotas","--service-code","eks")
$null = Invoke-AwsRead -Label "service-quotas-ec2" -CliArgs @("service-quotas","list-service-quotas","--service-code","ec2")
$null = Invoke-AwsRead -Label "waf-cloudfront-acls" -CallRegion "us-east-1" -CliArgs @("wafv2","list-web-acls","--scope","CLOUDFRONT")
$trailObj = Read-JsonFile (Join-Path $rawDir "$Region`__cloudtrail-trails.json")
if ($trailObj) {
    foreach ($trail in @($trailObj.trailList)) {
        if ($trail.Name) {
            $safeTrail = $trail.Name -replace '[^A-Za-z0-9._-]','_'
            $null = Invoke-AwsRead -Label "cloudtrail-$safeTrail-status" -CliArgs @("cloudtrail","get-trail-status","--name",$trail.TrailARN)
            $null = Invoke-AwsRead -Label "cloudtrail-$safeTrail-event-selectors" -CliArgs @("cloudtrail","get-event-selectors","--trail-name",$trail.TrailARN)
        }
    }
}
$zoneObj = Read-JsonFile (Join-Path $rawDir "global__route53-hosted-zones.json")
if ($zoneObj) {
    foreach ($zone in @($zoneObj.HostedZones)) {
        $zoneId = $zone.Id -replace '^/hostedzone/',''
        if ($zoneId) { $null = Invoke-AwsRead -Label "route53-zone-$zoneId-records" -GlobalCall -CliArgs @("route53","list-resource-record-sets","--hosted-zone-id",$zoneId) }
    }
}
$cfObj = Read-JsonFile (Join-Path $rawDir "us-east-1__cloudfront-distributions.json")
if ($cfObj -and $cfObj.DistributionList) {
    foreach ($dist in @($cfObj.DistributionList.Items)) {
        if ($dist.Id) { $null = Invoke-AwsRead -Label "cloudfront-$($dist.Id)-config" -CallRegion "us-east-1" -CliArgs @("cloudfront","get-distribution-config","--id",$dist.Id) }
    }
}

# 7. Terraform state and repo static configuration audit. Never read state contents.
Add-Note "`n[6/8] TERRAFORM STATE / REPOSITORY STATIC CONFIGURATION"
$repoReport = Join-Path $outDir "repository-inspection.txt"
$repoLines = [System.Collections.Generic.List[string]]::new()
$repoLines.Add("Repository root: $RepositoryRoot")
if (Test-Path -LiteralPath $RepositoryRoot -PathType Container) {
    $tfFiles = @(Get-ChildItem -LiteralPath $RepositoryRoot -Recurse -File -Include *.tf,*.tfvars,*.tfvars.example,*.yaml,*.yml,*.json,*.sh,*.md -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '[\\/](\.terraform|node_modules|\.git|dist|build|Phase2-Step1-Inspection|Phase2-AWS-Audit|AWS-Cost-Pause-Check)[\\/]' })
    $repoLines.Add("Files scanned: $($tfFiles.Count)")
    $terraformResources = [System.Collections.Generic.List[object]]::new()
    $regionHits = [System.Collections.Generic.List[object]]::new()
    $accountHits = [System.Collections.Generic.List[object]]::new()
    $ecrHits = [System.Collections.Generic.List[object]]::new()
    $namespaceHits = [System.Collections.Generic.List[object]]::new()
    foreach ($f in $tfFiles) {
        $content = Get-Content -LiteralPath $f.FullName -Raw -ErrorAction SilentlyContinue
        if ($null -eq $content) { continue }
        $relative = $f.FullName.Substring($RepositoryRoot.TrimEnd('\','/').Length).TrimStart('\','/')
        foreach ($m in [regex]::Matches($content,'resource\s+"(aws_[^"]+)"\s+"([^"]+)"')) {
            $terraformResources.Add([pscustomobject]@{File=$relative;Type=$m.Groups[1].Value;Name=$m.Groups[2].Value})
        }
        foreach ($m in [regex]::Matches($content,'ap-south-1|ap-southeast-2|us-east-1')) {
            $regionHits.Add([pscustomobject]@{File=$relative;Region=$m.Value;Line=(($content.Substring(0,$m.Index) -split "`n").Count)})
        }
        foreach ($m in [regex]::Matches($content,'(?<!\d)706016980205(?!\d)|(?<!\d)529976312668(?!\d)|(?<!\d)065328824019(?!\d)')) {
            $accountHits.Add([pscustomobject]@{File=$relative;AccountId=$m.Value;Line=(($content.Substring(0,$m.Index) -split "`n").Count)})
        }
        foreach ($m in [regex]::Matches($content,'arn:aws:ecr:[^:"\s]+:[0-9]{12}:repository/[A-Za-z0-9._/*-]+')) {
            $ecrHits.Add([pscustomobject]@{File=$relative;Arn=$m.Value})
        }
        foreach ($m in [regex]::Matches($content,'streaming-app-(dev|stg|staging)|streamingapp-capstone-[A-Za-z0-9-]+')) {
            $namespaceHits.Add([pscustomobject]@{File=$relative;Value=$m.Value})
        }
    }
    $terraformResources | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $outDir "repository-terraform-resources.csv")
    $regionHits | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $outDir "repository-region-references.csv")
    $accountHits | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $outDir "repository-account-id-references.csv")
    $ecrHits | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $outDir "repository-ecr-arn-references.csv")
    $namespaceHits | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $outDir "repository-namespace-and-name-references.csv")
    $repoLines.Add("Terraform resource declarations: $($terraformResources.Count)")
    $repoLines.Add("Region references: ap-south-1=$(@($regionHits | Where-Object Region -eq 'ap-south-1').Count); ap-southeast-2=$(@($regionHits | Where-Object Region -eq 'ap-southeast-2').Count); us-east-1=$(@($regionHits | Where-Object Region -eq 'us-east-1').Count)")
    $repoLines.Add("Account ID references: 706016980205=$(@($accountHits | Where-Object AccountId -eq '706016980205').Count); 529976312668=$(@($accountHits | Where-Object AccountId -eq '529976312668').Count); 065328824019=$(@($accountHits | Where-Object AccountId -eq '065328824019').Count)")
    $repoLines.Add("ECR ARN references: $($ecrHits.Count)")
    $repoLines.Add("Namespace/project-name references: $($namespaceHits.Count)")
    $repoLines.Add("Review CSVs for hard-coded Mumbai references, old account IDs, ECR region/account mismatches, and namespace drift.")
    $stateFiles = @(Get-ChildItem -LiteralPath $RepositoryRoot -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^(terraform\.tfstate|terraform\.tfstate\.backup|.*\.tfplan)$' -and $_.FullName -notmatch '[\\/]\.terraform[\\/]' } |
        Select-Object FullName,Length,LastWriteTime)
    $stateFiles | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $outDir "local-terraform-state-file-inventory.csv")
    $repoLines.Add("Local state/plan files found: $($stateFiles.Count). Contents were not opened.")
} else {
    $repoLines.Add("WARNING: RepositoryRoot not found. Static repository inspection was skipped.")
}
$repoLines | Set-Content -LiteralPath $repoReport -Encoding UTF8

# Capture remote Terraform state object metadata for known backend keys, never state contents.
$null = Invoke-AwsRead -Label "terraform-state-bucket-head" -GlobalCall -CliArgs @("s3api","head-bucket","--bucket","streamingapp-tfstate-8a4b578417838a617bba947a4f")
$null = Invoke-AwsRead -Label "terraform-state-prefix-list" -GlobalCall -CliArgs @("s3api","list-objects-v2","--bucket","streamingapp-tfstate-8a4b578417838a617bba947a4f","--max-keys","1000")

# 8. Summary and output package.
Add-Note "`n[7/8] CHECK COMPLETENESS"
$expectedCategories = @(
    "Identity/account guard","Billing/Cost Explorer/commitments","EC2/VPC/networking",
    "EKS/ECR/containers","RDS/EFS/other databases","S3/storage/state",
    "IAM/KMS/Secrets/SSM metadata","CloudWatch/logging/alarms",
    "AWS Config/CloudTrail/security services","Backup/retention",
    "DNS/ACM/CloudFront/WAF","Terraform static configuration"
)
$expectedCategories | ForEach-Object { $script:Notes.Add("Covered category: $_") }

$successCount = @($script:Checks | Where-Object Status -eq "SUCCESS").Count
$failureCount = @($script:Checks | Where-Object Status -eq "BLOCKED_OR_FAILED").Count
$script:Checks | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $outDir "inspection-summary.csv")
$script:Failures | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $outDir "inspection-failures.csv")
$script:Notes | Set-Content -LiteralPath (Join-Path $outDir "inspection-report.txt") -Encoding UTF8

$manifest = [pscustomobject]@{
    Account=$identity.Account
    CallerArn=$identity.Arn
    Region=$Region
    Profile=$Profile
    StartedAt=$stamp
    TotalChecks=$script:Checks.Count
    SuccessfulChecks=$successCount
    FailedOrBlockedChecks=$failureCount
    FailureRatePercent=if ($script:Checks.Count) {[math]::Round(100*$failureCount/$script:Checks.Count,2)} else {0}
    RepositoryRoot=$RepositoryRoot
    ReadOnly=$true
    SecretValuesRead=$false
    TerraformStateContentsRead=$false
}
$manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $outDir "inspection-manifest.json") -Encoding UTF8

$zipPath = Join-Path $OutputRoot ("Phase2-Step1-Inspection-" + $stamp + ".zip")
Compress-Archive -Path (Join-Path $outDir '*') -DestinationPath $zipPath -Force

Add-Note "`n[8/8] COMPLETE"
Add-Note "Successful checks: $successCount"
Add-Note "Blocked/failed checks: $failureCount"
Add-Note "Report ZIP: $zipPath"
Add-Note "READ-ONLY: no AWS resources were changed."
Write-Host "`nUpload the ZIP here. Do not upload Terraform state files, plan files, credentials, or secret values." -ForegroundColor Yellow
