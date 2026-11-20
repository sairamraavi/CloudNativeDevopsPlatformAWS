[CmdletBinding()]
param(
    [string]$Profile = "personal",
    [string]$ExpectedAccountId = "529976312668"
)

$ErrorActionPreference = "Stop"
$env:AWS_PAGER = ""
$env:AWS_CLI_AUTO_PROMPT = "off"
$env:AWS_DEFAULT_REGION = "ap-southeast-2"
$env:AWS_REGION = "ap-southeast-2"

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$root = Join-Path $PSScriptRoot "AWS-Cost-Pause-Check"
$outDir = Join-Path $root $stamp
$rawDir = Join-Path $outDir "raw"
New-Item -ItemType Directory -Force -Path $rawDir | Out-Null

$script:results = [System.Collections.Generic.List[object]]::new()

function Invoke-AwsCheck {
    param(
        [Parameter(Mandatory=$true)][string]$Label,
        [Parameter(Mandatory=$true)][string[]]$CliArgs,
        [string]$Region = ""
    )
    $argv = @($CliArgs) + @("--profile", $Profile, "--no-cli-pager", "--output", "json")
    if ($Region) { $argv += @("--region", $Region) }

    # Native AWS CLI failures must be captured, not promoted to terminating
    # PowerShell errors by PowerShell 7's native-command preference.
    $oldNativePreference = $PSNativeCommandUseErrorActionPreference
    try {
        if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
            $PSNativeCommandUseErrorActionPreference = $false
        }
        $oldErrorPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        $output = & aws @argv 2>&1
        $exitCode = $LASTEXITCODE
        $ErrorActionPreference = $oldErrorPreference
    }
    catch {
        $exitCode = 1
        $output = @($_.Exception.Message)
        if (Get-Variable -Name oldErrorPreference -ErrorAction SilentlyContinue) {
            $ErrorActionPreference = $oldErrorPreference
        }
    }
    finally {
        if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
            $PSNativeCommandUseErrorActionPreference = $oldNativePreference
        }
    }
    $text = ($output | ForEach-Object { "$_" }) -join "`n"
    $file = Join-Path $rawDir (($Label -replace '[^A-Za-z0-9_.-]','_') + ".json")
    Set-Content -LiteralPath $file -Value $text -Encoding UTF8

    $status = if ($exitCode -eq 0) { "SUCCESS" } else { "FAILED_OR_DENIED" }
    $count = ""
    if ($exitCode -eq 0 -and $text.Trim()) {
        try {
            $obj = $text | ConvertFrom-Json
            if ($null -ne $obj) {
                $props = @($obj.PSObject.Properties)
                foreach ($p in $props) {
                    if ($p.Value -is [array]) { $count = $p.Value.Count; break }
                }
            }
        } catch {}
    }
    $script:results.Add([pscustomobject]@{
        Label=$Label; Region=$Region; Status=$status; Count=$count
        ExitCode=$exitCode; File=$file
        Error=if ($exitCode -ne 0) { ($text -replace "`r?`n"," " ).Substring(0,[Math]::Min(700,($text -replace "`r?`n"," ").Length)) } else { "" }
    })
    return [pscustomobject]@{ ExitCode=$exitCode; Text=$text; File=$file }
}

Write-Host "AWS COST AND ACTIVE-RESOURCE CHECK (READ ONLY)"
Write-Host "Profile: $Profile | Expected account: $ExpectedAccountId"
Write-Host "Output: $outDir"

$id = Invoke-AwsCheck -Label "identity" -CliArgs @("sts","get-caller-identity") -Region "ap-southeast-2"
if ($id.ExitCode -ne 0) { throw "STS identity check failed. See raw\identity.json" }
$identity = $id.Text | ConvertFrom-Json
if ($identity.Account -ne $ExpectedAccountId) { throw "Wrong AWS account. Expected $ExpectedAccountId, got $($identity.Account). Stopping." }
Write-Host "Verified account: $($identity.Account)"
Write-Host "Caller: $($identity.Arn)"

# Cost Explorer data is delayed and the End date is exclusive. This checks through yesterday.
$today = (Get-Date).ToString("yyyy-MM-dd")
$monthStart = (Get-Date -Day 1).ToString("yyyy-MM-dd")
$thirtyDaysAgo = (Get-Date).AddDays(-30).ToString("yyyy-MM-dd")

Write-Host "`n===== BILLING / COST EXPLORER ====="
$null = Invoke-AwsCheck -Label "cost-mtd-by-service-region" -CliArgs @(
    "ce","get-cost-and-usage",
    "--time-period","Start=$monthStart,End=$today",
    "--granularity","MONTHLY",
    "--metrics","UnblendedCost","AmortizedCost",
    "--group-by","Type=DIMENSION,Key=SERVICE","Type=DIMENSION,Key=REGION"
) -Region "us-east-1"

$null = Invoke-AwsCheck -Label "cost-last-30-days-daily-by-service" -CliArgs @(
    "ce","get-cost-and-usage",
    "--time-period","Start=$thirtyDaysAgo,End=$today",
    "--granularity","DAILY",
    "--metrics","UnblendedCost",
    "--group-by","Type=DIMENSION,Key=SERVICE"
) -Region "us-east-1"

$null = Invoke-AwsCheck -Label "cost-forecast-current-month" -CliArgs @(
    "ce","get-cost-forecast",
    "--time-period","Start=$today,End=$((Get-Date -Day 1).AddMonths(1).ToString('yyyy-MM-dd'))",
    "--metric","UNBLENDED_COST",
    "--granularity","MONTHLY"
) -Region "us-east-1"

$null = Invoke-AwsCheck -Label "budgets-list" -CliArgs @(
    "budgets","describe-budgets","--account-id",$ExpectedAccountId
) -Region "us-east-1"

$null = Invoke-AwsCheck -Label "cost-anomaly-monitors" -CliArgs @(
    "ce","get-anomaly-monitors"
) -Region "us-east-1"

Write-Host "`n===== DISCOVER ENABLED REGIONS ====="
$regionsCall = Invoke-AwsCheck -Label "enabled-regions" -CliArgs @(
    "ec2","describe-regions","--all-regions"
) -Region "ap-southeast-2"
$regions = @("ap-south-1","ap-southeast-2")
if ($regionsCall.ExitCode -eq 0) {
    try {
        $regionObj = $regionsCall.Text | ConvertFrom-Json
        $enabled = @($regionObj.Regions | Where-Object {
            $_.OptInStatus -eq "opt-in-not-required" -or $_.OptInStatus -eq "opted-in"
        } | ForEach-Object { $_.RegionName })
        if ($enabled.Count -gt 0) { $regions = $enabled }
    } catch {}
}
Write-Host "Regions to inspect: $($regions -join ', ')"

# Regional services/resources that can continue to incur charges when applications are stopped.
$checks = @(
    @{Name="ec2-instances"; Args=@("ec2","describe-instances","--filters","Name=instance-state-name,Values=pending,running,stopping,stopped")},
    @{Name="ebs-volumes"; Args=@("ec2","describe-volumes")},
    @{Name="ebs-snapshots-owned"; Args=@("ec2","describe-snapshots","--owner-ids","self")},
    @{Name="nat-gateways"; Args=@("ec2","describe-nat-gateways")},
    @{Name="elastic-ip-addresses"; Args=@("ec2","describe-addresses")},
    @{Name="vpc-endpoints"; Args=@("ec2","describe-vpc-endpoints")},
    @{Name="eks-clusters"; Args=@("eks","list-clusters")},
    @{Name="load-balancers-v2"; Args=@("elbv2","describe-load-balancers")},
    @{Name="classic-load-balancers"; Args=@("elb","describe-load-balancers")},
    @{Name="rds-instances"; Args=@("rds","describe-db-instances")},
    @{Name="rds-snapshots"; Args=@("rds","describe-db-snapshots","--snapshot-type","manual")},
    @{Name="efs-file-systems"; Args=@("efs","describe-file-systems")},
    @{Name="lambda-functions"; Args=@("lambda","list-functions")},
    @{Name="cloudwatch-log-groups"; Args=@("logs","describe-log-groups")},
    @{Name="kms-keys"; Args=@("kms","list-keys")},
    @{Name="secrets-metadata"; Args=@("secretsmanager","list-secrets")},
    @{Name="ecs-clusters"; Args=@("ecs","list-clusters")},
    @{Name="dynamodb-tables"; Args=@("dynamodb","list-tables")},
    @{Name="elasticache-clusters"; Args=@("elasticache","describe-cache-clusters","--show-cache-node-info")},
    @{Name="opensearch-domains"; Args=@("opensearch","list-domain-names")},
    @{Name="redshift-clusters"; Args=@("redshift","describe-clusters")},
    @{Name="fsx-file-systems"; Args=@("fsx","describe-file-systems")},
    @{Name="sagemaker-endpoints"; Args=@("sagemaker","list-endpoints")}
)

foreach ($region in $regions) {
    Write-Host "`n===== REGION $region ====="
    foreach ($check in $checks) {
        $label = "$region-$($check.Name)"
        $null = Invoke-AwsCheck -Label $label -CliArgs $check.Args -Region $region
    }
}

Write-Host "`n===== GLOBAL RESOURCES ====="
$null = Invoke-AwsCheck -Label "s3-buckets" -CliArgs @("s3api","list-buckets") -Region "ap-southeast-2"
$null = Invoke-AwsCheck -Label "cloudfront-distributions" -CliArgs @("cloudfront","list-distributions") -Region "us-east-1"
$null = Invoke-AwsCheck -Label "route53-hosted-zones" -CliArgs @("route53","list-hosted-zones") -Region "us-east-1"
$null = Invoke-AwsCheck -Label "route53-health-checks" -CliArgs @("route53","list-health-checks") -Region "us-east-1"

# Inspect ECR repositories and image counts in each enabled region.
foreach ($region in $regions) {
    $repoCall = Invoke-AwsCheck -Label "$region-ecr-repositories" -CliArgs @("ecr","describe-repositories") -Region $region
    if ($repoCall.ExitCode -eq 0) {
        try {
            $repoObj = $repoCall.Text | ConvertFrom-Json
            foreach ($repo in @($repoObj.repositories)) {
                $safeName = ($repo.repositoryName -replace '[^A-Za-z0-9_.-]','_')
                $null = Invoke-AwsCheck -Label "$region-ecr-images-$safeName" -CliArgs @(
                    "ecr","describe-images","--repository-name",$repo.repositoryName
                ) -Region $region
            }
        } catch {}
    }
}

# S3 per-bucket metadata checks; no object contents are read.
$s3 = $script:results | Where-Object { $_.Label -eq "s3-buckets" -and $_.Status -eq "SUCCESS" } | Select-Object -First 1
if ($s3) {
    try {
        $bucketObj = Get-Content -LiteralPath $s3.File -Raw | ConvertFrom-Json
        foreach ($bucket in @($bucketObj.Buckets)) {
            $b = $bucket.Name
            $null = Invoke-AwsCheck -Label "s3-location-$b" -CliArgs @("s3api","get-bucket-location","--bucket",$b) -Region "ap-southeast-2"
            $null = Invoke-AwsCheck -Label "s3-versioning-$b" -CliArgs @("s3api","get-bucket-versioning","--bucket",$b) -Region "ap-southeast-2"
            $null = Invoke-AwsCheck -Label "s3-encryption-$b" -CliArgs @("s3api","get-bucket-encryption","--bucket",$b) -Region "ap-southeast-2"
        }
    } catch {}
}

$script:results | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $outDir "check-summary.csv")
$script:results | Where-Object Status -ne "SUCCESS" | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $outDir "check-failures.csv")

$report = @"
AWS COST AND ACTIVE-RESOURCE CHECK
Generated: $(Get-Date -Format o)
Account: $ExpectedAccountId
Profile: $Profile
Cost Explorer date range MTD: $monthStart to $today (end exclusive; through yesterday)
Cost Explorer trailing 30 days: $thirtyDaysAgo to $today (end exclusive)
Regions inspected: $($regions -join ', ')

SUCCESSFUL CHECKS: $(@($script:results | Where-Object Status -eq 'SUCCESS').Count)
FAILED / DENIED CHECKS: $(@($script:results | Where-Object Status -ne 'SUCCESS').Count)

IMPORTANT:
- Cost Explorer is the source for recorded charges, but data can lag by 24-48 hours.
- A failed check is not proof that a resource is absent.
- Resource inventory is not a bill; use the Cost Explorer service/region breakdown to identify actual charges.
- S3 object contents and Secrets Manager secret values were not read.
- This script performs read-only API calls and does not modify AWS resources.
"@
Set-Content -LiteralPath (Join-Path $outDir "README-report.txt") -Value $report -Encoding UTF8

$zipPath = Join-Path $PSScriptRoot "AWS-Cost-Pause-Check-$stamp.zip"
Compress-Archive -Path (Join-Path $outDir "*") -DestinationPath $zipPath -Force

Write-Host "`n===== COMPLETE ====="
Write-Host "Successful checks: $(@($script:results | Where-Object Status -eq 'SUCCESS').Count)"
Write-Host "Failed/denied checks: $(@($script:results | Where-Object Status -ne 'SUCCESS').Count)"
Write-Host "ZIP: $zipPath"
Write-Host "No AWS resources were modified."
