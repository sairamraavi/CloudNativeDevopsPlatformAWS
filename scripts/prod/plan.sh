#!/usr/bin/env bash
# Prepare one production stack plan in an isolated local directory.
set -euo pipefail
umask 077
root=$(cd "$(dirname "$0")/../.." && pwd)
case ${1:-} in
  data) stack=Terraform/prod-data; key=prod-data/terraform.tfstate ;;
  cluster) stack=Terraform/environments/prod; key=environments/prod/terraform.tfstate ;;
  *) echo 'Usage: bash scripts/prod/plan.sh data|cluster' >&2; exit 2 ;;
esac
: "${AWS_PROFILE:?Set the production AWS profile}"
: "${AWS_REGION:?Set the production region}"
: "${TF_VAR_expected_account_id:?Set the approved production account ID}"
: "${CAPSTONE_STATE_BUCKET:?Set the production bootstrap bucket}"
account=$(aws sts get-caller-identity --query Account --output text)
[[ $account == "$TF_VAR_expected_account_id" ]] || { echo 'AWS account mismatch' >&2; exit 1; }
aws s3api head-bucket --bucket "$CAPSTONE_STATE_BUCKET" --expected-bucket-owner "$account" >/dev/null
base="$HOME/.capstone/$account/$AWS_REGION/prod-planning/$1"
export TF_DATA_DIR="$base/data" TF_VAR_aws_region="$AWS_REGION" TF_WORKSPACE=default
mkdir -p "$base"
tf=(terraform "-chdir=$root/$stack")
"${tf[@]}" init -input=false -reconfigure -lockfile=readonly \
  -backend-config="bucket=$CAPSTONE_STATE_BUCKET" -backend-config="key=$key" \
  -backend-config="region=$AWS_REGION" -backend-config=encrypt=true -backend-config=use_lockfile=true
"${tf[@]}" validate
out=$(mktemp -d "$base/review.XXXXXXXX")
"${tf[@]}" plan -input=false -lock-timeout=60s -out="$out/prod.tfplan"
printf 'Review privately: terraform show %q\n' "$out/prod.tfplan"
