resource "aws_cloudwatch_log_group" "application" {
  name              = "/streamingapp-capstone/dev/application"
  retention_in_days = 3
}

resource "aws_cloudwatch_log_group" "jenkins" {
  name              = "/streamingapp-capstone/dev/jenkins"
  retention_in_days = 3
}

locals {
  cloudwatch_oidc_host = trimprefix(
    module.eks.cluster_oidc_issuer_url,
    "https://"
  )
}

resource "aws_iam_role" "application_logs" {
  name = "streamingapp-capstone-dev-application-logs"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = module.eks.oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.cloudwatch_oidc_host}:aud" = "sts.amazonaws.com"
          "${local.cloudwatch_oidc_host}:sub" = "system:serviceaccount:monitoring:fluent-bit"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "application_logs" {
  name = "write-application-logs"
  role = aws_iam_role.application_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogStream",
        "logs:DescribeLogStreams",
        "logs:PutLogEvents"
      ]
      Resource = "${aws_cloudwatch_log_group.application.arn}:*"
    }]
  })
}

resource "aws_iam_role_policy" "jenkins_logs" {
  name = "write-jenkins-service-logs"
  role = aws_iam_role.jenkins.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogStream",
        "logs:DescribeLogStreams",
        "logs:PutLogEvents"
      ]
      Resource = "${aws_cloudwatch_log_group.jenkins.arn}:*"
    }]
  })
}

output "application_logs_role_arn" {
  description = "IAM role for the application Fluent Bit collector."
  value       = aws_iam_role.application_logs.arn
}