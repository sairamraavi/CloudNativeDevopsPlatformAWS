variable "name_prefix" {
  description = "Project prefix for the ECR repository names."
  type        = string

  validation {
    condition = (
      length(var.name_prefix) <= 100 &&
      can(regex("^[a-zA-Z0-9-]*$", var.name_prefix))
    )
    error_message = "use a lowercase prefix starting with a letter, at most 100 characters."
  }
}

variable "services" {
  description = "application services required spearate iamge reopisitories."
  type        = set(string)

  default = [
    "frontend",
    "auth",
    "steaming",
    "admin",
    "chat"
  ]
  validation {
    condition = (
      length(var.services) > 0 &&
      alltrue([
        for service in var.services :
        can(regex("^[a-zA-Z0-9-]*$", service))
      ])
    )
    error_message = "Provide service names starting with a lowercase letter, using lowercase letters, digits, and hyphens, at most 50 characters each."
  }
}

variable "tags" {
  description = "Tags to apply to the ECR repositories."
  type        = map(string)
  default     = {}
}