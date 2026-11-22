#!/usr/bin/env bash
# Run from the workstation with its staging Terraform backend initialized.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
: "${AWS_PROFILE:=streamingapp}" "${AWS_REGION:=ap-south-1}"
export AWS_PROFILE AWS_REGION AWS_PAGER=""
account=$(aws sts get-caller-identity --query Account --output text)
dir="${STAGING_DIR:-$HOME/.capstone/$account/$AWS_REGION/staging}"
export TF_DATA_DIR="$dir/data"
cluster=$(terraform -chdir="$root/Terraform/environments/staging" output -raw eks_cluster_name)
role=$(aws eks list-access-entries --cluster-name "$cluster" --query 'accessEntries' --output json |
  python3 -c 'import json,sys; matches=[r for r in json.load(sys.stdin) if r.endswith("/streamingapp-capstone-eks-admin")]; role,=matches; print(role)')
ctx=streamingapp-capstone-staging
aws eks update-kubeconfig --name "$cluster" --alias "$ctx" --role-arn "$role" --kubeconfig "$dir/kubeconfig" >/dev/null
k(){ kubectl --kubeconfig "$dir/kubeconfig" --context "$ctx" "$@"; }
printf 'Cluster: %s   Region: %s\n' "$cluster" "$AWS_REGION"
aws eks describe-cluster --name "$cluster" --query 'cluster.[status,version]' --output text
k auth can-i list nodes
k wait --for=condition=Ready node --all --timeout=5m >/dev/null
k get nodes -L topology.kubernetes.io/zone
k get nodes -o json | python3 -c 'import json,sys; ns=json.load(sys.stdin)["items"]; zones={n["metadata"]["labels"]["topology.kubernetes.io/zone"] for n in ns if any(c["type"]=="Ready" and c["status"]=="True" for c in n["status"]["conditions"])}; assert len(zones)>=2,"Expected Ready nodes across two zones"'
for addon in vpc-cni coredns kube-proxy eks-pod-identity-agent aws-ebs-csi-driver metrics-server; do
  aws eks wait addon-active --cluster-name "$cluster" --addon-name "$addon"
  aws eks describe-addon --cluster-name "$cluster" --addon-name "$addon" --query 'addon.[addonName,status,addonVersion]' --output text
done
