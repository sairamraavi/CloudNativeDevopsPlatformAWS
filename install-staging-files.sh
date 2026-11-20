#!/usr/bin/env bash
set -Eeuo pipefail

REPO="/mnt/d/HeroVired/Capstone/Group_folder/CloudNativeDevopsPlatformAWS"
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/Terraform/environments/staging"
TARGET_DIR="$REPO/Terraform/environments/staging"

[[ -d "$REPO/.git" ]] || { echo "ERROR: repository not found: $REPO"; exit 1; }
[[ "$(git -C "$REPO" branch --show-current)" == "staging" ]] || {
  echo "ERROR: You must be on staging. No files copied."
  exit 1
}
[[ -d "$TARGET_DIR" ]] || { echo "ERROR: staging Terraform directory missing."; exit 1; }

FILES=(
  application-iam.tf
  cloudwatch-logs.tf
  jenkins-deployment-access.tf
  jenkins-monitoring.tf
  jenkins.tf
  metrics-server.tf
  jenkins-inputs.example.tfvars
)

for file in "${FILES[@]}"; do
  [[ -f "$SOURCE_DIR/$file" ]] || { echo "ERROR: package missing $file"; exit 1; }
  [[ ! -e "$TARGET_DIR/$file" ]] || {
    echo "ERROR: refusing to overwrite existing file: $TARGET_DIR/$file"
    exit 1
  }
done

echo "Target branch: staging"
echo "Target directory: $TARGET_DIR"
echo
echo "Files to add:"
printf '  %s\n' "${FILES[@]}"
echo
read -r -p "Type ADD-STAGING-FILES to copy these new files: " answer
[[ "$answer" == "ADD-STAGING-FILES" ]] || { echo "Cancelled."; exit 1; }

for file in "${FILES[@]}"; do
  cp -- "$SOURCE_DIR/$file" "$TARGET_DIR/$file"
done

echo
echo "Files copied. No existing file was overwritten."
echo "No Terraform init, validate, plan, apply, destroy, or AWS mutation was run."
echo
echo "Next: inspect the diff and provide Jenkins inputs before planning."
git -C "$REPO" status --short -- Terraform/environments/staging
