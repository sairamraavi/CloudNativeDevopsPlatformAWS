output "bucket_name" {
  description = "Ansible SSM transfer bucket name."
  value       = aws_s3_bucket.this.id
}

output "bucket_arn" {
  description = "Ansible SSM transfer bucket ARN."
  value       = aws_s3_bucket.this.arn
}
