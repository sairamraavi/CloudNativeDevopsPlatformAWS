variable "ansible_ssm_transfer_bucket_name" {
  description = "Globally unique S3 bucket name for temporary Ansible SSM transfers."
  type        = string
}

module "ssm_transfer" {
  source = "../../modules/s3-ssm-transfer"

  bucket_name = var.ansible_ssm_transfer_bucket_name
  tags        = local.common_tags
}

output "ansible_ssm_transfer_bucket" {
  description = "Temporary S3 bucket used by Ansible SSM file transfers."
  value       = module.ssm_transfer.bucket_name
}