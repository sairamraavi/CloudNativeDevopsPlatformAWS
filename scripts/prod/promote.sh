#!/usr/bin/env bash
set -euo pipefail
: "${IMAGE_TAG:?Missing verified build tag}" "${ECR_REGISTRY:?Missing build registry}"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
for env in staging prod; do
  aws eks update-kubeconfig --name "streamingapp-capstone-$env-eks" --alias "$env" --kubeconfig "$tmp/$env"
done
args=(--set-string "image.registry=$ECR_REGISTRY" --set-string "image.tag=$IMAGE_TAG" --set-string "frontend.tag=$IMAGE_TAG")
for svc in admin auth chat streaming frontend; do
  image=$(kubectl --kubeconfig "$tmp/staging" -n streaming-app-stg get deployment "$svc" -o jsonpath='{.spec.template.spec.containers[0].image}')
  digest=${image##*@}
  [[ $digest =~ ^sha256:[0-9a-f]{64}$ && $image == "$ECR_REGISTRY/streamingapp-capstone-$svc:$IMAGE_TAG@$digest" ]]
  key="services.$svc.digest"
  if [[ $svc == frontend ]]; then key=frontend.digest; fi
  args+=(--set-string "$key=$digest")
  printf '%s' "$image" > "$tmp/$svc"
done
helm upgrade streamingapp helm/streamingapp --kubeconfig "$tmp/prod" -n streaming-app-prod --reuse-values "${args[@]}" --rollback-on-failure --wait --timeout 10m
for svc in admin auth chat streaming frontend; do
  actual=$(kubectl --kubeconfig "$tmp/prod" -n streaming-app-prod get deployment "$svc" -o jsonpath='{.spec.template.spec.containers[0].image}')
  [[ $actual == "$(cat "$tmp/$svc")" ]]
done
