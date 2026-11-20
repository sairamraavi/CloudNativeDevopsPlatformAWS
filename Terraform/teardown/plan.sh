#!/usr/bin/env bash
# Preview removal of one initialized environment; save the plan privately.
set -euo pipefail
umask 077
case ${1:-} in
  dev|staging) env_name=$1 ;;
  *) echo 'Usage: bash Terraform/teardown/plan.sh dev|staging [absolute-path-to.tfvars]' >&2; exit 2 ;;
esac
[[ $# -le 2 ]] || exit 2
root=$(cd "$(dirname "$0")/../.." && pwd)
export AWS_PROFILE="${AWS_PROFILE:-streamingapp}" AWS_REGION="${AWS_REGION:-ap-south-1}"
: "${TF_VAR_expected_account_id:?Set the intended account ID from your deployment record}"
: "${CAPSTONE_STATE_BUCKET:?Set the state bucket name from that account bootstrap output}"
account=$(aws sts get-caller-identity --query Account --output text)
[[ $account == "$TF_VAR_expected_account_id" ]] || { echo 'AWS account mismatch' >&2; exit 1; }
base="$HOME/.capstone/$account/$AWS_REGION/$env_name"
export TF_DATA_DIR="${TF_DATA_DIR:-$base/data}"
python3 - "$TF_DATA_DIR/terraform.tfstate" "$CAPSTONE_STATE_BUCKET" "$env_name" "$AWS_REGION" <<'PY'
import json, sys
path, bucket, environment, region = sys.argv[1:]
with open(path) as f:
    backend = json.load(f)["backend"]
config = backend["config"]
if (backend["type"], config["bucket"], config["key"], config["region"]) != (
    "s3", bucket, f"environments/{environment}/terraform.tfstate", region
):
    sys.exit("Backend mismatch. Select the initialized data directory for this environment.")
PY
tf=(terraform "-chdir=$root/Terraform/environments/$env_name")
[[ $("${tf[@]}" workspace show) == default ]] || { echo 'This runbook expects the default workspace.' >&2; exit 1; }
args=()
if [[ $# == 2 ]]; then
  [[ $2 == /* && -r $2 ]] || { echo 'Supply a readable absolute tfvars path.' >&2; exit 2; }
  args+=("-var-file=$2")
fi
mkdir -p "$base/plans"
dir=$(mktemp -d "$base/plans/teardown.XXXXXXXX")
"${tf[@]}" plan -destroy -input=false -lock-timeout=60s ${args[@]+"${args[@]}"} "-var=expected_account_id=$account" "-var=aws_region=$AWS_REGION" -out="$dir/teardown.tfplan"
printf 'Private review plan: %s\n' "$dir/teardown.tfplan"
