variable "application_bucket_name" {
  description = "Globally unique S3 bucket name for application video and thumbnail storage."
  type        = string

  validation {
    condition = (
      length(var.application_bucket_name) >= 3 &&
      length(var.application_bucket_name) <= 63 &&
      can(regex("^[a-z0-9][a-z0-9.-]*[a-z0-9]$", var.application_bucket_name)) &&
      !can(regex("\\.\\.", var.application_bucket_name))
    )
    error_message = "Provide a valid S3 bucket name containing 3-63 lowercase letters, digits, dots, or hyphens."
  }
}

module "application_storage" {
  source = "../../modules/s3-app"

  bucket_name = var.application_bucket_name

  tags = local.common_tags
}

output "application_bucket_name" {
  description = "S3 bucket used by the application."
  value       = module.application_storage.bucket_name
}

output "application_bucket_arn" {
  description = "ARN of the application S3 bucket."
  value       = module.application_storage.bucket_arn
}
