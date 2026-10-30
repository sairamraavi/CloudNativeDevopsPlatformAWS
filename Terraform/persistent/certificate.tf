variable "application_domain" {
  description = "Public hostname for the streaming application."
  type        = string
  default     = "streaming.sairamraavi.com"
}

resource "aws_acm_certificate" "application" {
  domain_name       = var.application_domain
  validation_method = "DNS"
  key_algorithm     = "RSA_2048"

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name    = "streamingapp-capstone-application"
    Project = "streamingapp-capstone"
  }
}

output "application_certificate_arn" {
  value = aws_acm_certificate.application.arn
}

output "application_certificate_dns_records" {
  value = [
    for record in aws_acm_certificate.application.domain_validation_options : {
      name  = record.resource_record_name
      type  = record.resource_record_type
      value = record.resource_record_value
    }
  ]
}