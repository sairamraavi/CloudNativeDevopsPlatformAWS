# Reuse the five ECR repositories managed by the persistent Terraform stack.
data "aws_ecr_repository" "jenkins" {
  for_each = toset([
    "frontend",
    "auth",
    "streaming",
    "admin",
    "chat"
  ])

  name = "${var.project_name}-${each.key}"
}

variable "jenkins_instance_type" {
  description = "EC2 instance type for the Jenkins controller."
  type        = string
  default     = "t3.large"
}

module "jenkins" {
  source = "../../modules/jenkins"

  name_prefix       = local.name_prefix
  vpc_id            = module.networking.vpc_id
  private_subnet_id = module.networking.private_subnet_ids[0]
  instance_type     = var.jenkins_instance_type
  root_volume_size  = 30

  ecr_repository_arns = [
    for repository in data.aws_ecr_repository.jenkins :
    repository.arn
  ]

  eks_cluster_arn = module.eks.cluster_arn
  tags            = local.common_tags

  depends_on = [
    module.networking,
    module.eks
  ]
}

# Allow Jenkins to reach the private EKS API endpoint over HTTPS.
resource "aws_vpc_security_group_ingress_rule" "eks_from_jenkins" {
  security_group_id            = module.eks.cluster_security_group_id
  referenced_security_group_id = module.jenkins.security_group_id

  ip_protocol = "tcp"
  from_port   = 443
  to_port     = 443

  description = "Allow Jenkins controller to access the private EKS API."
}

# Register the Jenkins EC2 IAM role as an EKS principal.
resource "aws_eks_access_entry" "jenkins" {
  cluster_name  = module.eks.cluster_name
  principal_arn = module.jenkins.iam_role_arn
  type          = "STANDARD"

  tags = local.common_tags
}

# Required for the current Helm chart, which creates cluster-scoped resources.
resource "aws_eks_access_policy_association" "jenkins" {
  cluster_name  = module.eks.cluster_name
  principal_arn = aws_eks_access_entry.jenkins.principal_arn

  policy_arn = "arn:${data.aws_partition.current.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }
}

output "jenkins_instance_id" {
  description = "Jenkins EC2 instance ID."
  value       = module.jenkins.instance_id
}

output "jenkins_private_ip" {
  description = "Jenkins private IP address."
  value       = module.jenkins.private_ip
}

output "jenkins_iam_role_arn" {
  description = "Jenkins IAM role registered with EKS."
  value       = module.jenkins.iam_role_arn
}
