variable "expected_account_id" {
  description = "AWS account authorized for this deployment."
  type        = string
}

variable "aws_region" {
  description = "AWS region for shared resources."
  type        = string
  default     = "ap-southeast-2"
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
  source      = "../../modules/ecr"
  name_prefix = "streamingapp-capstone"

  services = [
    "frontend",
    "auth",
    "streaming",
    "admin",
    "chat"
  ]

  tags = {
    Project     = "streamingapp-capstone"
    Environment = "shared"
    ManagedBy   = "Terraform"
  }
}
