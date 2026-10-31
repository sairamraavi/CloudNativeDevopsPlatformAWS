
terraform {
  required_version = ">= 1.10.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0.0, < 7.0.0"
    }

    helm = {
      source  = "hashicorp/helm"
      version = ">= 3.0.0, < 4.0.0"
    }
  }

  backend "s3" {}
}

# Project configuration
variable "project_name" {
  description = "Project name used in resource naming and tagging."
  type        = string
  default     = "streamingapp-capstone"

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.project_name))
    error_message = "Project name must contain lowercase letters, numbers, and hyphens only."
  }
}

variable "environment" {
  description = "Deployment environment name."
  type        = string
  default     = "dev"

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.environment))
    error_message = "Environment must contain lowercase letters, numbers, and hyphens only."
  }
}

# Common naming and tagging
locals {
  name_prefix = "${var.project_name}-${var.environment}"

  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

# AWS account configuration
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

# Network configuration
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

# AWS provider configuration
provider "aws" {
  region              = var.aws_region
  allowed_account_ids = [var.expected_account_id]

  default_tags {
    tags = local.common_tags
  }
}

# Helm provider configuration for EKS
provider "helm" {
  kubernetes = {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"

      args = [
        "eks",
        "get-token",
        "--region",
        var.aws_region,
        "--cluster-name",
        module.eks.cluster_name,
      ]
    }
  }
}

# Networking infrastructure
module "networking" {
  source = "../../modules/networking"

  name_prefix        = local.name_prefix
  vpc_cidr           = "10.0.0.0/16"
  availability_zones = var.availability_zones
  nat_mode           = var.nat_mode

  tags = local.common_tags
}

# Outputs
output "vpc_id" {
  description = "ID of the application VPC."
  value       = module.networking.vpc_id
}

output "public_subnet_ids" {
  description = "IDs of the public subnets."
  value       = module.networking.public_subnet_ids
}

output "private_subnet_ids" {
  description = "IDs of the private subnets."
  value       = module.networking.private_subnet_ids
}

output "nat_public_ips" {
  description = "Public IP addresses assigned to NAT gateways."
  value       = module.networking.nat_public_ips
}
