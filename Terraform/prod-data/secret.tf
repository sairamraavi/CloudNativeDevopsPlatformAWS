resource "aws_secretsmanager_secret" "application_prod" {
  name                    = "streamingapp-capstone/prod/application"
  description             = "Production MongoDB URI and JWT signing secret"
  recovery_window_in_days = 7

  tags = {
    Environment = "prod"
    Purpose     = "Application configuration"
  }

  lifecycle {
    prevent_destroy = true
  }
}

output "application_prod_secret_arn" {
  description = "Application secret ARN; does not expose secret values"
  value       = aws_secretsmanager_secret.application_prod.arn
}

output "application_prod_secret_name" {
  description = "Application secret name."
  value       = aws_secretsmanager_secret.application_prod.name
}