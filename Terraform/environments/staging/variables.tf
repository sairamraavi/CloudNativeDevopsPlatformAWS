variable "expected_account_id" {
  type        = string
  description = "AWS account ID."
}

variable "aws_region" {
  type        = string
  description = "AWS region."
  default     = "ap-southeast-2"
}

variable "availability_zones" {
  type        = list(string)
  description = "Staging availability zones."
  default     = ["ap-southeast-2a", "ap-southeast-2b"]

  validation {
    condition     = length(var.availability_zones) == 2
    error_message = "Exactly two availability zones are required."
  }
}

variable "eks_admin_role_arn" {
  type        = string
  description = "IAM role granted EKS administrator access."
}

variable "eks_public_access_cidrs" {
  type        = list(string)
  description = "IPv4 CIDR ranges allowed to access the EKS public API."

  validation {
    condition = (
      length(var.eks_public_access_cidrs) > 0 &&
      alltrue([
        for cidr in var.eks_public_access_cidrs :
        can(cidrnetmask(cidr))
      ])
    )
    error_message = "Provide one or more valid IPv4 CIDR ranges."
  }
}