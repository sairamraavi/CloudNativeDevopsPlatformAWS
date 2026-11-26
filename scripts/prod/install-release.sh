#!/usr/bin/env bash
# First production installation from a staging-tested release.
set -euo pipefail
cd "$(dirname "$0")/../.."
tag=${1:?Pass the staging release tag}
: "${AWS_PROFILE:?}" "${AWS_REGION:?}" "${TF_VAR_expected_account_id:?}"
account=$(aws sts get-caller-identity --query Account --output text)
[[ $account == "$TF_VAR_expected_account_id" ]] || { echo "AWS account mismatch" >&2; exit 1; }
base="$HOME/.capstone/$account/$AWS_REGION"
cluster_output() { TF_DATA_DIR="$base/prod-planning/cluster/data" terraform -chdir=Terraform/environments/prod output "$@"; }
data_output() { TF_DATA_DIR="$base/prod-planning/data/data" terraform -chdir=Terraform/prod-data output -raw "$1"; }
ctx=streamingapp-capstone-prod
ns=streaming-app-prod
prod=(kubectl --context "$ctx" -n "$ns")
stg=(kubectl --kubeconfig "${STG_KUBE:-$base/staging/kubeconfig}" --context streamingapp-capstone-staging -n streaming-app-stg)
endpoint=$(cluster_output -raw eks_cluster_endpoint)
actual=$("${prod[@]}" config view --minify -o jsonpath='{.clusters[0].cluster.server}')
[[ $actual == "$endpoint" ]] || { echo "Production endpoint mismatch" >&2; exit 1; }
"${prod[@]}" wait --for=condition=Ready externalsecret/streamingapp-application --timeout=60s
cert=$(data_output application_certificate_arn)
host=$(aws acm describe-certificate --certificate-arn "$cert" --query 'Certificate.DomainName' --output text)
bucket=$(data_output media_bucket_name)
roles=$(cluster_output -json media_workload_role_arns)
registry="$account.dkr.ecr.$AWS_REGION.amazonaws.com"
args=(--set-string "image.registry=$registry" --set-string "image.tag=$tag" --set-string "frontend.tag=$tag"
      --set ingress.enabled=true --set-string "ingress.host=$host" --set-string "ingress.certificateArn=$cert"
      --set-string "app.clientUrls=https://$host" --set-string "app.streamingPublicUrl=https://$host"
      --set-string "app.s3Bucket=$bucket" --set-string "app.awsRegion=$AWS_REGION")
for svc in admin streaming; do
  role=$(python3 -c 'import sys,json; print(json.load(sys.stdin)[sys.argv[1]])' "$svc" <<< "$roles")
  args+=(--set-string "services.$svc.roleArn=$role")
done
services=(admin auth chat frontend streaming)
images=()
for svc in "${services[@]}"; do
  "${stg[@]}" rollout status "deploy/$svc" --timeout=60s
  image=$("${stg[@]}" get deploy "$svc" -o jsonpath='{.spec.template.spec.containers[0].image}')
  digest=${image##*@}
  [[ $digest =~ ^sha256:[0-9a-f]{64}$ && $image == "$registry/streamingapp-capstone-$svc:$tag@$digest" ]] || { echo "Unexpected staging image for $svc" >&2; exit 1; }
  images+=("$image")
  key="services.$svc.digest"
  if [[ $svc == frontend ]]; then key=frontend.digest; fi
  args+=(--set-string "$key=$digest")
done
helm install streamingapp helm/streamingapp --kube-context "$ctx" -n "$ns" "${args[@]}" --wait --timeout 10m
for i in "${!services[@]}"; do
  actual=$("${prod[@]}" get deployment "${services[i]}" -o jsonpath='{.spec.template.spec.containers[0].image}')
  [[ $actual == "${images[i]}" ]] || { echo "Production image mismatch: ${services[i]}" >&2; exit 1; }
  echo "Verified production $actual"
done
"${prod[@]}" get ingress streamingapp
