
#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# STAGING CONFIGURATION PREFLIGHT + VALIDATION + PLAN
#
# - staging branch only
# - no develop branch checkout or modification
# - no AWS infrastructure provisioning
# - no terraform apply or destroy
# - preserves uncommitted changes
# - refuses unsafe backend reconfiguration
# ============================================================

REPO="/mnt/d/HeroVired/Capstone/Group_folder/CloudNativeDevopsPlatformAWS"
STAGING_DIR="$REPO/Terraform/environments/staging"

AWS_PROFILE="personal"
AWS_REGION="ap-southeast-2"
EXPECTED_ACCOUNT="529976312668"

STATE_BUCKET="streamingapp-tfstate-8a4b578417838a617bba947a4f"
STATE_KEY="staging/terraform.tfstate"

# Set YES only after independently confirming fresh state.
CONFIRM_FRESH_STATE="NO"

# Set YES only after all missing parity files have been
# implemented with staging-specific configuration.
CONFIRM_PARITY_COMPLETE="NO"

# ============================================================
# Helpers
# ============================================================

fail() {
    echo
    echo "ERROR: $1"
    echo "Stopped safely. No infrastructure was provisioned."
    exit 1
}

section() {
    echo
    echo "============================================================"
    echo "$1"
    echo "============================================================"
}

command -v aws >/dev/null 2>&1 || fail "AWS CLI not installed."
command -v terraform >/dev/null 2>&1 || fail "Terraform not installed."
command -v python3 >/dev/null 2>&1 || fail "Python 3 not installed."
command -v git >/dev/null 2>&1 || fail "Git not installed."

[[ -d "$REPO/.git" ]] || fail "Repository not found."
[[ -d "$STAGING_DIR" ]] || fail "Staging Terraform directory not found."

cd "$REPO"

# ============================================================
# 1. Branch and repository safety
# ============================================================

section "1. REPOSITORY SAFETY"

CURRENT_BRANCH="$(git branch --show-current)"

[[ "$CURRENT_BRANCH" == "staging" ]] ||
    fail "Current branch is '$CURRENT_BRANCH', not staging."

echo "[OK] Current branch: staging"

echo
echo "Existing working-tree changes:"
git status --short

echo
echo "[INFO] No checkout, reset, clean, stash or commit will be run."

# ============================================================
# 2. AWS credential and identity safety
# ============================================================

section "2. AWS IDENTITY"

# Avoid silently using environment credentials instead of
# the explicitly selected AWS profile.
for name in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN; do
    if [[ -n "${!name:-}" ]]; then
        fail "$name is set in the environment. Resolve credential precedence before continuing."
    fi
done

export AWS_PROFILE
export AWS_DEFAULT_REGION="$AWS_REGION"
export AWS_REGION

IDENTITY="$(aws sts get-caller-identity \
    --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" \
    --output json)" ||
    fail "AWS STS identity check failed."

ACCOUNT="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["Account"])' <<< "$IDENTITY")"

[[ "$ACCOUNT" == "$EXPECTED_ACCOUNT" ]] ||
    fail "Unexpected AWS account: $ACCOUNT"

echo "[OK] AWS profile: $AWS_PROFILE"
echo "[OK] AWS account: $ACCOUNT"
echo "[OK] AWS region: $AWS_REGION"

# ============================================================
# 3. Terraform and provider checks
# ============================================================

section "3. TERRAFORM TOOLING"

cd "$STAGING_DIR"

terraform version

[[ -f ".terraform.lock.hcl" ]] ||
    fail "Staging provider lock file is missing."

[[ -f "backend.tf" ]] ||
    fail "Staging backend.tf is missing."

echo
echo "[OK] Provider lock file exists."
echo "[OK] Backend configuration file exists."

# ============================================================
# 4. Configuration parity checks
# ============================================================

section "4. DEVELOP CONFIGURATION PARITY"

# These components exist in the supplied develop baseline.
# Their staging equivalents must be implemented and reviewed.
REQUIRED_FILES=(
    "application-iam.tf"
    "cloudwatch-logs.tf"
    "jenkins-deployment-access.tf"
    "jenkins-monitoring.tf"
    "jenkins.tf"
    "metrics-server.tf"
)

MISSING=0

for file in "${REQUIRED_FILES[@]}"; do
    if [[ -f "$STAGING_DIR/$file" ]]; then
        echo "[OK] $file"
    else
        echo "[MISSING] $file"
        MISSING=1
    fi
done

if [[ "$MISSING" -eq 1 ]]; then
    echo
    echo "Staging is not yet at configuration parity with develop."
    echo "Implement and review the missing staging equivalents first."
    [[ "$CONFIRM_PARITY_COMPLETE" == "YES" ]] ||
        fail "Configuration parity has not been confirmed."
    fail "Parity confirmation was YES, but required files are still missing."
fi

[[ "$CONFIRM_PARITY_COMPLETE" == "YES" ]] ||
    fail "Set CONFIRM_PARITY_COMPLETE=YES only after reviewing the staging equivalents."

# ============================================================
# 5. Terraform formatting
# ============================================================

section "5. TERRAFORM FORMATTING"

terraform fmt -check -recursive "$STAGING_DIR" ||
    fail "Staging Terraform formatting check failed."

terraform fmt -check -recursive "$REPO/Terraform/modules" ||
    fail "Shared Terraform module formatting check failed."

echo "[OK] Formatting checks passed."

# ============================================================
# 6. Remote state history verification
# ============================================================

section "6. REMOTE STATE HISTORY"

echo "[INFO] Checking all versions and delete markers for exact state key."

VERSIONS_JSON="$(aws s3api list-object-versions \
    --bucket "$STATE_BUCKET" \
    --prefix "$STATE_KEY" \
    --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" \
    --output json)" ||
    fail "Could not inspect remote state history. Do not initialize."

python3 - "$STATE_KEY" <<< "$VERSIONS_JSON" <<'PY'
import json
import sys

key = sys.argv[1]
data = json.load(sys.stdin)

versions = [
    x for x in data.get("Versions", [])
    if x.get("Key") == key
]
markers = [
    x for x in data.get("DeleteMarkers", [])
    if x.get("Key") == key
]

if versions or markers:
    print("State object versions or delete markers exist:")
    for item in versions + markers:
        print(
            "  Version:", item.get("VersionId"),
            "DeleteMarker:", item.get("IsDeleteMarker", False)
        )
    sys.exit(1)

print("No versions or delete markers found for exact state key.")
PY

[[ "$?" -eq 0 ]] ||
    fail "Remote state history exists. Investigate before initialization."

# Check current object separately.
HEAD_ERROR="$(mktemp)"
if aws s3api head-object \
    --bucket "$STATE_BUCKET" \
    --key "$STATE_KEY" \
    --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" \
    >/dev/null 2>"$HEAD_ERROR"; then
    rm -f "$HEAD_ERROR"
    fail "Current remote state object exists. Do not initialize as fresh."
else
    if grep -Eqi '404|Not Found|NoSuchKey' "$HEAD_ERROR"; then
        echo "[OK] Exact current state key returned 404."
    else
        cat "$HEAD_ERROR"
        rm -f "$HEAD_ERROR"
        fail "State check failed for a reason other than confirmed 404."
    fi
fi
rm -f "$HEAD_ERROR"

[[ "$CONFIRM_FRESH_STATE" == "YES" ]] ||
    fail "State absence was checked. Independently confirm fresh-state decision before initialization."

# ============================================================
# 7. Terraform initialization
# ============================================================

section "7. TERRAFORM INIT"

# Intentionally no -reconfigure and no -migrate-state.
# If Terraform detects a backend configuration mismatch,
# it must stop rather than silently changing backend metadata.

terraform init \
    -input=false \
    -backend-config="bucket=$STATE_BUCKET" \
    -backend-config="key=$STATE_KEY" \
    -backend-config="region=$AWS_REGION" \
    -backend-config="encrypt=true" \
    -backend-config="use_lockfile=true" ||
    fail "Terraform init failed. Review backend configuration; do not force reconfiguration."

# ============================================================
# 8. Terraform validation
# ============================================================

section "8. TERRAFORM VALIDATION"

terraform validate ||
    fail "Terraform validation failed."

echo "[OK] Terraform validation passed."

# ============================================================
# 9. Fresh plan
# ============================================================

section "9. GENERATE REVIEW PLAN"

PLAN_FILE="staging-review-$(date +%Y%m%d-%H%M%S).tfplan"

[[ ! -e "$PLAN_FILE" ]] ||
    fail "Plan file already exists: $PLAN_FILE"

terraform plan \
    -input=false \
    -var-file="staging.tfvars" \
    -out="$PLAN_FILE" ||
    fail "Terraform plan failed."

echo
echo "============================================================"
echo "STAGING PLAN GENERATED"
echo "============================================================"
echo "Plan: $STAGING_DIR/$PLAN_FILE"
echo
echo "Review it with:"
echo "terraform show \"$PLAN_FILE\""
echo
echo "No infrastructure was applied."
echo "No develop files or branch were modified."
echo "Do not apply this plan without a separate review and approval."
echo "============================================================"
