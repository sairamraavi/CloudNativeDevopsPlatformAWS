# Metrics Server EKS add-on, matching the develop add-on version.
# Confirm AWS offers this version for EKS 1.36 in ap-southeast-2
# before running a plan or provisioning.

resource "aws_eks_addon" "metrics_server" {
  cluster_name  = module.eks.cluster_name
  addon_name    = "metrics-server"
  addon_version = "v0.9.0-eksbuild.14"

  resolve_conflicts_on_create = "NONE"
  resolve_conflicts_on_update = "PRESERVE"

  tags = {
    Name        = "streamingapp-capstone-staging-metrics-server"
    Project     = "streamingapp-capstone"
    Environment = "staging"
    ManagedBy   = "Terraform"
  }

  depends_on = [module.eks]
}
