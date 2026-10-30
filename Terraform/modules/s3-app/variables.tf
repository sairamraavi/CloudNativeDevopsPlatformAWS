variable "bucket_name" {
  description = "Globally unique name for the application S3 bucket."
  type        = string

  validation {
    condition = (
      length(var.bucket_name) >= 3 &&
      length(var.bucket_name) <= 63 &&
      can(regex("^[a-z0-9][a-z0-9.-]*[a-z0-9]$", var.bucket_name)) &&
      !can(regex("\\.\\.", var.bucket_name))
    )
    error_message = "Provide a valid S3 bucket name containing 3-63 lowercase letters, digits, dots, or hyphens."
  }
}

variable "tags" {
  description = "Tags applied to the application bucket."
  type        = map(string)
  default     = {}
}
