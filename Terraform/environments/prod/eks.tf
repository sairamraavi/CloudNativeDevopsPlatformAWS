variable "eks_admin_role_arn" {
  description = "Existing IAM role granted adminstrator access to eks."
  type        = string
}

variable "eks_public_access_cidrs" {
  description = "Adminstrator workstation IPV4 /32 CIDRs"
  type        = list(string)
}

module "eks" {
  source              = "../../modules/eks"
  name_prefix         = "streamingapp-capstone-prod"
  kubernetes_version  = "1.36"
  private_subnet_ids  = module.networking.private_subnet_ids
  admin_role_arn      = var.eks_admin_role_arn
  public_access_cidrs = distinct(concat(var.eks_public_access_cidrs, ["${data.aws_instance.jenkins.public_ip}/32"]))

  node_instance_types  = var.node_instance_types
  node_max_size_per_az = 2
  log_retention_days   = 30
  addon_versions = {
    vpc_cni            = "v1.22.4-eksbuild.3"
    coredns            = "v1.14.7-eksbuild.11"
    kube_proxy         = "v1.36.0-eksbuild.48"
    pod_identity_agent = "v1.4.1-eksbuild.2"
  }
  tags = {
    Project     = "streamingapp-capstone"
    Environment = "prod"
    ManagedBy   = "Terraform"
  }
  depends_on = [module.networking]
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
output "autoscaler_role_arn" {
  value = module.eks.autoscaler_role_arn
}
locals {
  application_oidc_host = trimprefix(module.eks.cluster_oidc_issuer_url, "https://")
}

variable "node_instance_types" {
  description = "Provisional on-demand worker types; verify availability and size against load tests."
  type        = list(string)
  default     = ["t3.large"]
}
