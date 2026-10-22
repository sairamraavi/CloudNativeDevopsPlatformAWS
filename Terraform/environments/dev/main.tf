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
  description = "Region for project infrastructure."
  type        = string
  default     = "ap-south-1"
}

variable "availability_zones" {
  description = "Two AZs for project networking."
  type        = list(string)
}

variable "nat_mode" {
  description = "NAT deployment mode."
  type        = string
  default     = "none"

  validation {
    condition     = contains(["none", "single", "per_az"], var.nat_mode)
    error_message = "Choose none, single, or per_az."
  }
}

provider "aws" {
  region              = var.aws_region
  allowed_account_ids = [var.expected_account_id]

  default_tags {
    tags = {
      Project     = "streamingapp-capstone"
      Environment = "dev"
      ManagedBy   = "Terraform"
    }
  }
}

module "networking" {
  source = "../../modules/networking"

  name_prefix        = "streamingapp-capstone-dev"
  vpc_cidr           = "10.0.0.0/16"
  availability_zones = var.availability_zones
  nat_mode           = var.nat_mode

  tags = {
    Project     = "streamingapp-capstone"
    Environment = "dev"
    ManagedBy   = "Terraform"
  }
}

output "vpc_id" {
  value = module.networking.vpc_id
}

output "public_subnet_ids" {
  value = module.networking.public_subnet_ids
}

output "private_subnet_ids" {
  value = module.networking.private_subnet_ids
}

output "nat_public_ips" {
  value = module.networking.nat_public_ips
}