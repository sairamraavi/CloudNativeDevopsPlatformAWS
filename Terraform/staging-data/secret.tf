resource "aws_secretsmanager_secret" "application_staging" {
  name                    = "streamingapp-capstone/staging/application"
  description             = "Staging MongoDB URI and JWT signing secret"
  recovery_window_in_days = 7

  tags = {
    Environment = "staging"
    Purpose     = "Application configuration"
  }

  lifecycle {
    prevent_destroy = true
  }
}

output "application_staging_secret_arn" {
  description = "Application secret ARN; does not expose secret values"
  value       = aws_secretsmanager_secret.application_staging.arn
}

output "application_staging_secret_name" {
  description = "Application secret name."
  value       = aws_secretsmanager_secret.application_staging.name
}