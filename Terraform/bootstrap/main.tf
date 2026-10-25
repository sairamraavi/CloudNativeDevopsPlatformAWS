variable "aws_region" {
  description = "AWS region for project resources."
  type        = string
  default     = "ap-south-1"
}

variable "expected_account_id" {
  description = "AWS account explicitly authorized for this deployment."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.expected_account_id))
    error_message = "Provide a 12-digit AWS account ID."
  }
}

provider "aws" {
  region              = var.aws_region
  allowed_account_ids = [var.expected_account_id]

  default_tags {
    tags = {
      Project     = "streamingapp-capstone"
      Environment = "bootstrap"
      ManagedBy   = "Terraform"
    }
  }
}

data "aws_caller_identity" "current" {}

output "deployment_account_id" {
  description = "Verified account used by this configuration."
  value       = data.aws_caller_identity.current.account_id
}