
resource "aws_secretsmanager_secret" "application" {
  name                    = "streamingapp-capstone/staging/application"
  description             = "Staging application configuration, including MongoDB URI and JWT signing secret."
  recovery_window_in_days = 7

  tags = {
    Project     = "streamingapp-capstone"
    Environment = "staging"
    Purpose     = "Staging application configuration"
    ManagedBy   = "Terraform"
  }

  lifecycle {
    prevent_destroy = true
  }
}

output "application_secret_arn" {
  description = "Staging application secret ARN. Does not expose secret values."
  value       = aws_secretsmanager_secret.application.arn
}

output "application_secret_name" {
  description = "Staging application secret name."
  value       = aws_secretsmanager_secret.application.name
}
