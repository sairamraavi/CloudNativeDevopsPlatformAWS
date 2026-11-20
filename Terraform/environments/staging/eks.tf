
module "eks" {
  source = "../../modules/eks"

  # Disable OIDC and all OIDC-dependent IAM resources in staging.
  enable_oidc = false

  name_prefix        = "streamingapp-capstone-staging"
  kubernetes_version = "1.36"

  private_subnet_ids = module.networking.private_subnet_ids

  admin_role_arn      = var.eks_admin_role_arn
  public_access_cidrs = var.eks_public_access_cidrs

  # Cost-conscious staging configuration.
  node_instance_types  = ["c7i-flex.large"]
  node_max_size_per_az = 2

  node_group_mode   = "shared"
  node_min_size     = 1
  node_desired_size = 1
  node_max_size     = 2

  log_retention_days = 7

  addon_versions = {
    vpc_cni            = "v1.23.2-eksbuild.10"
    coredns            = "v1.14.7-eksbuild.35"
    kube_proxy         = "v1.36.0-eksbuild.65"
    pod_identity_agent = "v1.4.1-eksbuild.3"
  }

  tags = {
    Project     = "streamingapp-capstone"
    Environment = "staging"
    ManagedBy   = "Terraform"
  }

  depends_on = [module.networking]
}