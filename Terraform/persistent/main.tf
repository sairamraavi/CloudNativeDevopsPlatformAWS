terraform {
  required_version = ">= 1.10.0, < 2.0.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0.0, < 7.0.0"
    }
  }
  backend "s3" {}
}

variable "expected_account_id" {
  description = "AWS account authorized for this deployment."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.expected_account_id))
    error_message = "Provide a 12-digit AWS account ID."
  }
}

variable "aws_region" {
  description = "Region for persistent project resources."
  type        = string
  default     = "ap-south-1"
}

provider "aws" {
  region              = var.aws_region
  allowed_account_ids = [var.expected_account_id]

  default_tags {
    tags = {
      Project     = "streamingapp-capstone"
      Environment = "shared"
      ManagedBy   = "Terraform"
    }
  }
}

module "ecr" {
  source      = "../modules/ecr"
  name_prefix = "streamingapp-capstone"
  services    = ["frontend", "auth", "streaming", "admin", "chat"]
  tags = {
    Project     = "streamingapp-capstone"
    Environment = "shared"
    ManagedBy   = "Terraform"
  }
}

output "repository_urls" {
  description = "Image repository URLs keyed by service."
  value       = module.ecr.repository_urls
}

output "repository_arns" {
  description = "Image repository ARNs for scoping IAM permissions."
  value       = module.ecr.repository_arns
}

output "repository_names" {
  description = "Image repository names keyed by service."
  value       = module.ecr.repository_names
}