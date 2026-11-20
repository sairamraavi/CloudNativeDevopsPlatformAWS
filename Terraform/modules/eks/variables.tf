variable "name_prefix" {
  description = "Streaming App project and environment prefix for EKS resources"
  type        = string

  validation {
    condition = (
      length(var.name_prefix) <= 40 &&
      can(regex("^[a-z][a-z0-9-]*$", var.name_prefix))
    )
    error_message = "use a lowercase prefix starting with a letter at most 40 characters."
  }
}

variable "tags" {
  description = "Tags applied to resources managed by this module."
  type        = map(string)
  default     = {}
}

variable "kubernetes_version" {
  description = "Explicit Kubernetes minor version for the cluster."
  type        = string

  validation {
    condition     = can(regex("^1\\.[0-9]+$", var.kubernetes_version))
    error_message = "Specify a Kubernetes minor version, such as 1.36."
  }
}

variable "private_subnet_ids" {
  description = "Private subnets spanning at least two Availability Zones."
  type        = list(string)

  validation {
    condition     = length(distinct(var.private_subnet_ids)) >= 2
    error_message = "Provide at least two distinct private subnet IDs."
  }
}

variable "admin_role_arn" {
  description = "Existing IAM role granted administrator access to this cluster."
  type        = string

  validation {
    condition = can(regex(
      "^arn:[^:]+:iam::[0-9]{12}:role/.+$",
      var.admin_role_arn
    ))
    error_message = "Provide an IAM role ARN, not an STS assumed-role session ARN."
  }
}

variable "public_access_cidrs" {
  description = "IPv4 CIDR ranges allowed to access the EKS public API."
  type        = list(string)

  validation {
    condition = (
      length(var.public_access_cidrs) > 0 &&
      alltrue([
        for cidr in var.public_access_cidrs :
        can(cidrnetmask(cidr))
      ])
    )
    error_message = "Provide one or more valid IPv4 CIDR ranges."
  }
}

variable "log_retention_days" {
  description = "Retention period for EKS control-plane logs."
  type        = number
  default     = 7

  validation {
    condition     = contains([7, 14, 30, 60, 90], var.log_retention_days)
    error_message = "Choose 7, 14, 30, 60, or 90 days."
  }
}

variable "node_instance_types" {
  description = "AMD64 EC2 Instance type for managed worker nodes."
  type        = list(string)
  default     = ["t3.large"]

  validation {
    condition     = length(var.node_instance_types) > 0
    error_message = "Provide atleast one AMD64 instance type"
  }
}

variable "node_max_size_per_az" {
  description = "Maximum worker nodes in each AZ"
  type        = number
  default     = 2

  validation {
    condition = (
      var.node_max_size_per_az >= 1 &&
      var.node_max_size_per_az <= 3 &&
      floor(var.node_max_size_per_az) == var.node_max_size_per_az
    )
    error_message = "Choose the interger between 1 and 3"
  }
}

variable "addon_versions" {
  description = "Explicit add-on versions compatible with the selected Kubernetes version."
  type = object({
    vpc_cni            = string
    coredns            = string
    kube_proxy         = string
    pod_identity_agent = string
  })
}

variable "node_group_mode" {
  description = "Node group topology: per_az creates one node group per subnet; shared creates one node group across all private subnets."
  type        = string
  default     = "per_az"

  validation {
    condition     = contains(["per_az", "shared"], var.node_group_mode)
    error_message = "node_group_mode must be either per_az or shared."
  }
}

variable "node_min_size" {
  description = "Minimum node count for shared node group mode."
  type        = number
  default     = 1

  validation {
    condition     = var.node_min_size >= 0
    error_message = "node_min_size must be zero or greater."
  }
}

variable "node_desired_size" {
  description = "Desired node count for shared node group mode."
  type        = number
  default     = 1

  validation {
    condition     = var.node_desired_size >= 0
    error_message = "node_desired_size must be zero or greater."
  }
}

variable "node_max_size" {
  description = "Maximum node count for shared node group mode."
  type        = number
  default     = 2

  validation {
    condition     = var.node_max_size >= 1
    error_message = "node_max_size must be at least 1."
  }
  validation {
    condition = (
      var.node_min_size <= var.node_desired_size &&
      var.node_desired_size <= var.node_max_size &&
      floor(var.node_min_size) == var.node_min_size &&
      floor(var.node_desired_size) == var.node_desired_size &&
      floor(var.node_max_size) == var.node_max_size
    )

    error_message = "Node scaling values must be whole numbers and satisfy min_size <= desired_size <= max_size."
  }
}


variable "enable_oidc" {
  description = "Whether to create OIDC provider and IRSA workload roles."
  type        = bool
  default     = true
}
