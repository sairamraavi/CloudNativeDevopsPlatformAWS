variable "eks_admin_role_arn" {
  description = "Existing IAM role granted adminstrator access to eks."
  type        = string
}

variable "eks_public_access_cidrs" {
  description = "Adminstrator workstation IPV4 /32 CIDRs"
  type        = list(string)
}

resource "terraform_data" "eks_network_guard" {
  input = var.nat_mode

  lifecycle {
    precondition {
      condition     = var.nat_mode == "per_az"
      error_message = "This deployment requires nat_mode=per_az for  private-node egress in both Azs."
    }
  }
}

module "eks" {
  source              = "../../modules/eks"
  name_prefix         = "streamingapp-capstone-dev"
  kubernetes_version  = "1.36"
  private_subnet_ids  = module.networking.private_subnet_ids
  admin_role_arn      = var.eks_admin_role_arn
  public_access_cidrs = var.eks_public_access_cidrs

  node_instance_types  = ["t3.large"]
  node_max_size_per_az = 2
  log_retention_days   = 7
  addon_versions = {
    vpc_cni            = "v1.22.4-eksbuild.3"
    coredns            = "v1.14.7-eksbuild.11"
    kube_proxy         = "v1.36.0-eksbuild.48"
    pod_identity_agent = "v1.4.1-eksbuild.2"
  }
  tags = {
    Project     = "streamingapp-capstone"
    Environment = "dev"
    ManagedBy   = "Terraform"
  }
  depends_on = [module.networking, terraform_data.eks_network_guard, ]
}

output "eks_cluster_name" {
  value = module.eks.cluster_name
}
output "eks_cluster_endpoint" {
  value = module.eks.cluster_endpoint
}
output "eks_cluster_security_group_id" {
  value = module.eks.cluster_security_group_id
}