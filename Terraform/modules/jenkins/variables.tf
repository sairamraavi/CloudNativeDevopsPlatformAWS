variable "name_prefix" {
  description = "Project and environment resource name prefix."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]*$", var.name_prefix))
    error_message = "Use a lowercase name prefix starting with a letter."
  }
}

variable "vpc_id" {
  description = "VPC where the Jenkins instance will run."
  type        = string
}

variable "private_subnet_id" {
  description = "Private subnet for the Jenkins EC2 instance."
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type for Jenkins."
  type        = string
  default     = "t3.large"
}

variable "root_volume_size" {
  description = "Encrypted gp3 root volume size in GiB."
  type        = number
  default     = 30

  validation {
    condition     = var.root_volume_size >= 20 && var.root_volume_size <= 100
    error_message = "Jenkins root volume must be between 20 and 100 GiB."
  }
}

variable "ecr_repository_arns" {
  description = "ECR repository ARNs Jenkins is allowed to push images to."
  type        = list(string)

  validation {
    condition     = length(var.ecr_repository_arns) > 0
    error_message = "Provide at least one ECR repository ARN."
  }
}

variable "eks_cluster_arn" {
  description = "EKS cluster ARN Jenkins needs to describe."
  type        = string
}

variable "tags" {
  description = "Common resource tags."
  type        = map(string)
  default     = {}
}
