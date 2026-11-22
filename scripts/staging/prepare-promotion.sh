#!/usr/bin/env bash
set -euo pipefail
umask 077
cd "$(dirname "$0")/../.."
export AWS_PROFILE="${AWS_PROFILE:-streamingapp}" AWS_REGION="${AWS_REGION:-ap-south-1}"
account=$(aws sts get-caller-identity --query Account --output text)
base="$HOME/.capstone/$account/$AWS_REGION"
export TF_DATA_DIR="$base/staging/data"
tf(){ terraform -chdir=Terraform/environments/staging "$@"; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# Recover the inputs used for this existing foundation from its saved plan.
tf show -json "$base/staging/workloads.tfplan" | python3 -c 'import json,sys; print(json.dumps({k:v["value"] for k,v in json.load(sys.stdin)["variables"].items()}))' > "$tmp/staging.tfvars.json"
tf plan -input=false -var-file="$tmp/staging.tfvars.json" -out="$tmp/access.plan"
tf show -json "$tmp/access.plan" | python3 -c '
import json,sys
allowed={"aws_iam_role_policy.jenkins_staging":["create"],"aws_eks_access_entry.jenkins":["create"],"aws_eks_access_policy_association.jenkins":["create"],"module.eks.aws_eks_cluster.this":["update"]}
for r in json.load(sys.stdin)["resource_changes"]:
    c=r["change"]
    if r["mode"]=="data" or c["actions"]==["no-op"]: continue
    if allowed.get(r["address"])!=c["actions"]: sys.exit("Review unexpected change: "+r["address"])
    if r["address"]=="module.eks.aws_eks_cluster.this":
        a,b=c["before"],c["after"]
        for obj in (a,b):
            obj["vpc_config"][0].pop("public_access_cidrs",None)
        if a!=b: sys.exit("Review additional EKS changes before applying.")
'
tf apply "$tmp/access.plan"
tf output -json > "$tmp/cluster.json"
TF_DATA_DIR="$base/staging-data/data" terraform -chdir=Terraform/staging-data output -json > "$tmp/data.json"
python3 - "$tmp" <<'PY'
import json,sys,pathlib
p=pathlib.Path(sys.argv[1])
c=json.loads((p/"cluster.json").read_text())
d=json.loads((p/"data.json").read_text())
role=c["media_workload_role_arns"]["value"]
host="staging.sairamraavi.com"
v={"services":{s:{"roleArn":arn} for s,arn in role.items()},
   "ingress":{"enabled":True,"host":host,"certificateArn":d["application_certificate_arn"]["value"]},
   "app":{"clientUrls":"https://"+host,"streamingPublicUrl":"https://"+host,"s3Bucket":d["media_bucket_name"]["value"]}}
(p/"values.json").write_text(json.dumps(v))
PY
k=(kubectl --kubeconfig "$base/staging/kubeconfig" --context streamingapp-capstone-staging)
"${k[@]}" get ingressclass alb
"${k[@]}" -n streaming-app-stg create configmap streamingapp-promotion-values --from-file="values.json=$tmp/values.json" --dry-run=client -o yaml | "${k[@]}" apply -f -
