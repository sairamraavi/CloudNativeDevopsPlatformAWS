#!/usr/bin/env bash
# Run on the workstation after recreating the dev Terraform environment.
set -euo pipefail
if [[ $# != 1 || ! -d $1 ]]; then
  echo "Usage: $0 /private/path/to/capstone-backup-directory" >&2
  exit 2
fi
backup_dir=$(cd "$1" && pwd -P)
root=$(cd "$(dirname "$0")/.." && pwd -P)
dev="$root/Terraform/environments/dev"
(cd "$backup_dir" && shasum -a 256 -c SHA256SUMS)
CAPSTONE_JENKINS_IP=$(terraform -chdir="$dev" output -raw jenkins_public_ip)
CAPSTONE_CLUSTER_NAME=$(terraform -chdir="$dev" output -raw eks_cluster_name)
export CAPSTONE_JENKINS_IP CAPSTONE_CLUSTER_NAME
export CAPSTONE_BACKUP_DIR="$backup_dir"
export AWS_REGION="${AWS_REGION:-ap-south-1}"
cd "$root/Ansible"
ansible jenkins -m ping
ansible-playbook playbooks/jenkins.yml -e @group_vars/all/main.yml --skip-tags cloudflared
ansible-playbook playbooks/recover-dev-tools.yml
