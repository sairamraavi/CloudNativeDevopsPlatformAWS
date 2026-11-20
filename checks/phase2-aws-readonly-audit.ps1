#requires -Version 5.1
<#
PHASE 2 / PART 1: READ-ONLY AWS AUDIT
Run after: aws login --profile personal
No AWS resources are created, changed, or deleted.
No secret values, SSM parameter values, S3 object contents, or credentials are retrieved.
#>
[CmdletBinding()]
param(
    [string]$Profile = "personal",
    [string]$ExpectedAccount = "529976312668",
    [string]$OutputRoot = ""
)
$ErrorActionPreference = "Stop"
$env:AWS_PAGER = ""
$env:AWS_CLI_AUTO_PROMPT = "off"
# Default region for global AWS CLI calls such as STS and S3
$env:AWS_DEFAULT_REGION = "ap-southeast-2"
$env:AWS_REGION = "ap-southeast-2"
if ([string]::IsNullOrWhiteSpace($OutputRoot)) { $OutputRoot = Join-Path $PSScriptRoot "Phase2-AWS-Audit" }
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$out = Join-Path $OutputRoot $stamp
$raw = Join-Path $out "raw"
New-Item -ItemType Directory -Force -Path $raw | Out-Null
$summary = [System.Collections.Generic.List[object]]::new()
$failures = [System.Collections.Generic.List[object]]::new()
$report = [System.Collections.Generic.List[string]]::new()

function Invoke-AuditCall {
    param([string]$Label,[string[]]$CliArgs,[string]$Region="global",[switch]$GlobalCall)
    $scope = if ($GlobalCall) { "global" } else { $Region }
    $safe = $Label -replace '[^A-Za-z0-9._-]','_'
    $file = Join-Path $raw "$scope`__$safe.json"
    $a = @($CliArgs) + @("--profile",$Profile,"--no-cli-pager","--output","json")
    if (-not $GlobalCall) { $a += @("--region",$Region) }
    try {
        $r = & aws @a 2>&1
        $code = $LASTEXITCODE
        $txt = ($r | Out-String).Trim()
        if ($code -eq 0) {
            $txt | Set-Content -LiteralPath $file -Encoding UTF8
            $n = 0
            try {
                $o = $txt | ConvertFrom-Json
                foreach ($k in @("Vpcs","Subnets","RouteTables","InternetGateways","NatGateways","Addresses","SecurityGroups","Reservations","Volumes","Snapshots","AutoScalingGroups","LoadBalancers","TargetGroups","DBInstances","FileSystems","repositories","Certificates","SecretList","logGroups","metricAlarms","Topics","QueueUrls","Functions","BackupVaultList","BackupPlansList","Roles","Policies","OpenIDConnectProviderList","Buckets","Distributions","HostedZones")) {
                    if ($null -ne $o.$k) { $n += @($o.$k).Count }
                }
            } catch {}
            $summary.Add([pscustomobject]@{Scope=$scope;Check=$Label;Status="SUCCESS";Count=$n;File=$file})
            return $txt
        }
        $failures.Add([pscustomobject]@{Scope=$scope;Check=$Label;ExitCode=$code;Error=$txt})
        $summary.Add([pscustomobject]@{Scope=$scope;Check=$Label;Status="BLOCKED_OR_FAILED";Count="";File=""})
        return $null
    } catch {
        $failures.Add([pscustomobject]@{Scope=$scope;Check=$Label;ExitCode="EXCEPTION";Error=$_.Exception.Message})
        $summary.Add([pscustomobject]@{Scope=$scope;Check=$Label;Status="BLOCKED_OR_FAILED";Count="";File=""})
        return $null
    }
}
function Say([string]$s) { $report.Add($s); Write-Host $s }

Say "PHASE 2 AWS READ-ONLY AUDIT"
Say "Started: $(Get-Date -Format o)"
Say "Profile: $Profile | Expected account: $ExpectedAccount"
Say "Output: $out"
if (-not (Get-Command aws -ErrorAction SilentlyContinue)) { throw "AWS CLI not found. Install AWS CLI v2." }

$idText = Invoke-AuditCall -Label "caller-identity" -CliArgs @("sts","get-caller-identity") -GlobalCall
if (-not $idText) { throw "Authentication failed. Run aws login --profile $Profile and rerun." }
$id = $idText | ConvertFrom-Json
if ($id.Account -ne $ExpectedAccount) { throw "Wrong AWS account. Expected $ExpectedAccount; received $($id.Account). Stopped." }
Say "Verified account: $($id.Account)"
Say "Caller ARN: $($id.Arn)"

$regText = Invoke-AuditCall -Label "available-regions" -CliArgs @("ec2","describe-regions","--all-regions") -GlobalCall
$regions = @()
if ($regText) {
    try { $regions = @(($regText | ConvertFrom-Json).Regions | Where-Object { $_.OptInStatus -in @("opt-in-not-required","opted-in") } | ForEach-Object RegionName) } catch {}
}
if ($regions.Count -eq 0) {
    $regions = @("ap-south-1","ap-southeast-2")
    Say "WARNING: Region discovery failed; only known project regions will be audited."
}
Say "Regions: $($regions -join ', ')"

$regionalChecks = @(
    @("vpcs","ec2","describe-vpcs"),
    @("subnets","ec2","describe-subnets"),
    @("route-tables","ec2","describe-route-tables"),
    @("internet-gateways","ec2","describe-internet-gateways"),
    @("nat-gateways","ec2","describe-nat-gateways"),
    @("elastic-ips","ec2","describe-addresses"),
    @("security-groups","ec2","describe-security-groups"),
    @("instances","ec2","describe-instances"),
    @("volumes","ec2","describe-volumes"),
    @("owned-snapshots","ec2","describe-snapshots","--owner-ids","self"),
    @("autoscaling-groups","autoscaling","describe-auto-scaling-groups"),
    @("eks-clusters","eks","list-clusters"),
    @("load-balancers","elbv2","describe-load-balancers"),
    @("target-groups","elbv2","describe-target-groups"),
    @("rds-instances","rds","describe-db-instances"),
    @("rds-snapshots","rds","describe-db-snapshots"),
    @("efs","efs","describe-file-systems"),
    @("ecr-repositories","ecr","describe-repositories"),
    @("acm-certificates","acm","list-certificates"),
    @("secrets-metadata","secretsmanager","list-secrets"),
    @("kms-keys","kms","list-keys"),
    @("cloudwatch-log-groups","logs","describe-log-groups"),
    @("cloudwatch-alarms","cloudwatch","describe-alarms"),
    @("sns-topics","sns","list-topics"),
    @("sqs-queues","sqs","list-queues"),
    @("lambda-functions","lambda","list-functions"),
    @("backup-vaults","backup","list-backup-vaults"),
    @("backup-plans","backup","list-backup-plans"),
    @("ssm-managed-instances","ssm","describe-instance-information")
)
foreach ($region in $regions) {
    Say "`n===== REGION $region ====="
    foreach ($c in $regionalChecks) {
        $label = $c[0]
        $args = @($c[1..($c.Count-1)])
        $null = Invoke-AuditCall -Label $label -CliArgs $args -Region $region
    }
    # Enumerate EKS child resources only for clusters returned successfully.
    $cf = Join-Path $raw "$region`__eks-clusters.json"
    if (Test-Path $cf) {
        try {
            $clusters = (Get-Content -Raw $cf | ConvertFrom-Json).clusters
            foreach ($cluster in $clusters) {
                $s = $cluster -replace '[^A-Za-z0-9._-]','_'
                $null = Invoke-AuditCall -Label "eks-$s-describe" -CliArgs @("eks","describe-cluster","--name",$cluster) -Region $region
                $ngText = Invoke-AuditCall -Label "eks-$s-nodegroups" -CliArgs @("eks","list-nodegroups","--cluster-name",$cluster) -Region $region
                $null = Invoke-AuditCall -Label "eks-$s-addons" -CliArgs @("eks","list-addons","--cluster-name",$cluster) -Region $region
                if ($ngText) {
                    foreach ($ng in ($ngText | ConvertFrom-Json).nodegroups) {
                        $null = Invoke-AuditCall -Label "eks-$s-nodegroup-$ng" -CliArgs @("eks","describe-nodegroup","--cluster-name",$cluster,"--nodegroup-name",$ng) -Region $region
                    }
                }
            }
        } catch { $failures.Add([pscustomobject]@{Scope=$region;Check="eks-child-discovery";ExitCode="EXCEPTION";Error=$_.Exception.Message}) }
    }
    # ECR image metadata only; no image downloads.
    $ef = Join-Path $raw "$region`__ecr-repositories.json"
    if (Test-Path $ef) {
        try {
            foreach ($repo in (Get-Content -Raw $ef | ConvertFrom-Json).repositories) {
                $rn = $repo.repositoryName
                $s = $rn -replace '[^A-Za-z0-9._-]','_'
                $null = Invoke-AuditCall -Label "ecr-$s-images" -CliArgs @("ecr","describe-images","--repository-name",$rn) -Region $region
                $null = Invoke-AuditCall -Label "ecr-$s-lifecycle" -CliArgs @("ecr","get-lifecycle-policy","--repository-name",$rn) -Region $region
            }
        } catch { $failures.Add([pscustomobject]@{Scope=$region;Check="ecr-child-discovery";ExitCode="EXCEPTION";Error=$_.Exception.Message}) }
    }
    # Secret metadata only. Never call get-secret-value.
    $sf = Join-Path $raw "$region`__secrets-metadata.json"
    if (Test-Path $sf) {
        try {
            foreach ($secret in (Get-Content -Raw $sf | ConvertFrom-Json).SecretList) {
                if ($secret.Name -match "streamingapp|capstone") {
                    $s = $secret.Name -replace '[^A-Za-z0-9._-]','_'
                    $null = Invoke-AuditCall -Label "secret-$s-description" -CliArgs @("secretsmanager","describe-secret","--secret-id",$secret.ARN) -Region $region
                }
            }
        } catch { $failures.Add([pscustomobject]@{Scope=$region;Check="secret-child-discovery";ExitCode="EXCEPTION";Error=$_.Exception.Message}) }
    }
}

Say "`n===== GLOBAL / ACCOUNT-WIDE ====="
$globalChecks = @(
    @("iam-account-summary","iam","get-account-summary"),
    @("iam-roles","iam","list-roles"),
    @("iam-instance-profiles","iam","list-instance-profiles"),
    @("iam-oidc-providers","iam","list-open-id-connect-providers"),
    @("iam-local-policies","iam","list-policies","--scope","Local"),
    @("s3-buckets","s3api","list-buckets"),
    @("cloudfront-distributions","cloudfront","list-distributions"),
    @("route53-hosted-zones","route53","list-hosted-zones"),
    @("route53-health-checks","route53","list-health-checks"),
    @("organizations-info","organizations","describe-organization")
)
foreach ($c in $globalChecks) {
    $null = Invoke-AuditCall -Label $c[0] -CliArgs @($c[1..($c.Count-1)]) -GlobalCall
}

# Bucket metadata/config only. Never list or download general bucket contents.
$bf = Join-Path $raw "global__s3-buckets.json"
if (Test-Path $bf) {
    try {
        foreach ($b in (Get-Content -Raw $bf | ConvertFrom-Json).Buckets) {
            $name = $b.Name
            $s = $name -replace '[^A-Za-z0-9._-]','_'
            foreach ($entry in @(
                @("location","get-bucket-location"),
                @("versioning","get-bucket-versioning"),
                @("encryption","get-bucket-encryption"),
                @("public-access","get-public-access-block"),
                @("ownership","get-bucket-ownership-controls"),
                @("lifecycle","get-bucket-lifecycle-configuration"),
                @("policy-status","get-bucket-policy-status")
            )) {
                $null = Invoke-AuditCall -Label "s3-$s-$($entry[0])" -CliArgs @("s3api",$entry[1],"--bucket",$name) -GlobalCall
            }
            if ($name -eq "streamingapp-tfstate-8a4b578417838a617bba947a4f") {
                $null = Invoke-AuditCall -Label "terraform-state-object-list" -CliArgs @("s3api","list-objects-v2","--bucket",$name,"--max-keys","1000") -GlobalCall
                $null = Invoke-AuditCall -Label "terraform-state-bucket-versioning" -CliArgs @("s3api","list-object-versions","--bucket",$name,"--max-keys","1000") -GlobalCall
            }
        }
    } catch { $failures.Add([pscustomobject]@{Scope="global";Check="s3-child-discovery";ExitCode="EXCEPTION";Error=$_.Exception.Message}) }
}

# Local Terraform state filenames only; state file contents are never opened.
$repo = Join-Path $PSScriptRoot "CloudNativeDevopsPlatformAWS"
if (Test-Path $repo) {
    Get-ChildItem -LiteralPath $repo -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^(terraform\.tfstate|terraform\.tfstate\.backup|.*\.tfplan)$' } |
        Select-Object FullName,Length,LastWriteTime |
        Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $out "local-terraform-state-file-inventory.csv")
}

$summary | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $out "audit-summary.csv")
$failures | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $out "audit-failures.csv")
$report | Set-Content -Encoding UTF8 -Path (Join-Path $out "audit-report.txt")
Say "`n===== COMPLETE ====="
Say "Successful checks: $(@($summary | Where-Object Status -eq 'SUCCESS').Count)"
Say "Blocked/failed checks: $(@($summary | Where-Object Status -eq 'BLOCKED_OR_FAILED').Count)"
Say "Output folder: $out"
Say "No AWS resources were modified."
$report | Set-Content -Encoding UTF8 -Path (Join-Path $out "audit-report.txt")
Write-Host "`nCreate a ZIP of the output folder and upload it here. Do not include local state/plan files." -ForegroundColor Yellow
