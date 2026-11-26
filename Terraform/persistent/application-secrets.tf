resource "aws_secretsmanager_secret" "application_dev" {
  name                    = "streamingapp-capstone/dev/application"
  description             = "Description application MangoDB URI and JWT singing secret"
  recovery_window_in_days = 7

  tags = {
    Environment = "dev"
    Purpose     = "Application configuration"
  }

  lifecycle {
    prevent_destroy = true
  }
}

output "application_dev_secret_arn" {
  description = "Application secret ARN; does not expose secret values"
  value       = aws_secretsmanager_secret.application_dev.arn
}

output "application_dev_secret_name" {
  description = "Application secret name."
  value       = aws_secretsmanager_secret.application_dev.name
}