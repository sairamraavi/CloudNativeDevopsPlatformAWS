variable "name_prefix" {
  description = "Prefix for project networking resource names."
  type        = string

  validation {
    condition = (
      length(var.name_prefix) <= 40 &&
      can(regex("^[a-z][a-z0-9-]*$", var.name_prefix))
    )
    error_message = "Use a lowercase prefix starting with a letter, at most 40 characters."
  }
}

variable "vpc_cidr" {
  description = "IPv4 /16 network reserved for this VPC."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition = (
      can(cidrnetmask(var.vpc_cidr)) &&
      can(regex("/16$", var.vpc_cidr))
    )
    error_message = "Provide a valid IPv4 /16 CIDR."
  }
}

variable "availability_zones" {
  description = "Two distinct Availability Zones in the deployment region."
  type        = list(string)

  validation {
    condition = (
      length(var.availability_zones) == 2 &&
      length(distinct(var.availability_zones)) == 2
    )
    error_message = "Provide exactly two distinct Availability Zones."
  }
}

variable "tags" {
  description = "Tags applied to project networking resources."
  type        = map(string)
  default     = {}
}

variable "nat_mode" {
  description = "Zonal NAT mode development mode: none single, or per_az."
  type        = string
  default     = "none"

  validation {
    condition     = contains(["none", "single", "per_az"], var.nat_mode)
    error_message = "NAT mode must be none, single, or per_az."
  }
}