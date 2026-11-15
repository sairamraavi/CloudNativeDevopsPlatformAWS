#!/usr/bin/env bash
set -euo pipefail
if [[ ! ${RELEASE_TAG:-} =~ ^[[:xdigit:]]{12}-[0-9]+$ ]]; then
  echo 'Enter the verified dev image tag under Build with Parameters.' >&2
  exit 1
fi
account=$(aws sts get-caller-identity --query Account --output text)
registry="$account.dkr.ecr.$AWS_REGION.amazonaws.com"
ns=streaming-app-stg
ctx=streamingapp-capstone-staging
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
aws eks update-kubeconfig --name streamingapp-capstone-staging-eks --alias "$ctx" --kubeconfig "$tmp/config"
k=(kubectl --kubeconfig "$tmp/config" --context "$ctx" -n "$ns")
"${k[@]}" wait --for=condition=Ready externalsecret/streamingapp-application --timeout=60s
"${k[@]}" get configmap streamingapp-promotion-values -o 'jsonpath={.data.values\.json}' > "$tmp/values.json"
args=(--set-string "image.registry=$registry" --set-string "image.tag=$RELEASE_TAG" --set-string "frontend.tag=$RELEASE_TAG")
for svc in admin auth chat frontend streaming; do
  repo="streamingapp-capstone-$svc"
  image="$registry/$repo:$RELEASE_TAG"
  dev=(kubectl --kubeconfig /var/lib/jenkins/.kube/config --context streamingapp-capstone-dev -n streaming-app-dev)
  "${dev[@]}" rollout status deployment/"$svc" --timeout=90s
  test "$("${dev[@]}" get deployment "$svc" -o 'jsonpath={.spec.template.spec.containers[0].image}')" = "$image"
  digest=$(aws ecr describe-images --repository-name "$repo" --image-ids "imageTag=$RELEASE_TAG" --query 'imageDetails[0].imageDigest' --output text)
  [[ $digest =~ ^sha256:[0-9a-f]{64}$ ]]
  key="services.$svc.digest"
  if [[ $svc == frontend ]]; then key=frontend.digest; fi
  args+=(--set-string "$key=$digest")
  echo "$image@$digest" > "$tmp/$svc"
done
helm upgrade --install streamingapp helm/streamingapp --kubeconfig "$tmp/config" --kube-context "$ctx" -n "$ns" -f "$tmp/values.json" "${args[@]}" --wait --timeout 10m
for svc in admin auth chat frontend streaming; do
  "${k[@]}" rollout status deployment/"$svc" --timeout=120s
  image=$("${k[@]}" get deployment "$svc" -o 'jsonpath={.spec.template.spec.containers[0].image}')
  test "$image" = "$(cat "$tmp/$svc")"
  printf 'Verified staging %s\n' "$image"
done
