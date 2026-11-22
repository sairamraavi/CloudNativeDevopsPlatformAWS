#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
export AWS_PROFILE="${AWS_PROFILE:-streamingapp}" AWS_REGION="${AWS_REGION:-ap-south-1}"
account=$(aws sts get-caller-identity --query Account --output text)
dir="${STAGING_DIR:-$HOME/.capstone/$account/$AWS_REGION/staging}"
ctx=streamingapp-capstone-staging
ns=streaming-app-stg
role=$(TF_DATA_DIR="$dir/data" terraform -chdir="$root/Terraform/environments/staging" output -raw secret_reader_role_arn)
cluster=$(TF_DATA_DIR="$dir/data" terraform -chdir="$root/Terraform/environments/staging" output -raw eks_cluster_name)
k=(kubectl --kubeconfig "$dir/kubeconfig" --context "$ctx")
endpoint=$(aws eks describe-cluster --name "$cluster" --query cluster.endpoint --output text)
[[ "$("${k[@]}" config view --minify -o jsonpath='{.clusters[0].cluster.server}')" == "$endpoint" ]] || { echo 'Check the staging kubeconfig endpoint.' >&2; exit 1; }
h=(--kubeconfig "$dir/kubeconfig" --kube-context "$ctx")
helm upgrade --install external-secrets external-secrets --repo https://charts.external-secrets.io --version 2.14.0 "${h[@]}" -n external-secrets --create-namespace --wait --timeout 5m
helm upgrade --install application-secrets "$root/helm/application-secrets" "${h[@]}" -n "$ns" --create-namespace --set-string secretReader.roleArn="$role" --set-string awsRegion="$AWS_REGION" --set-string remoteSecretName=streamingapp-capstone/staging/application
for resource in secretstore/streamingapp-aws-secrets externalsecret/streamingapp-application; do
  "${k[@]}" -n "$ns" wait --for=condition=Ready "$resource" --timeout=180s
done
"${k[@]}" -n "$ns" get secret streamingapp-application -o go-template='{{range $key, $value := .data}}{{printf "%s\n" $key}}{{end}}'
