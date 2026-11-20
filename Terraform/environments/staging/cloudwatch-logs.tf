
# Staging CloudWatch log groups and Jenkins logging permissions.

resource "aws_cloudwatch_log_group" "application" {
  name              = "/streamingapp-capstone/staging/application"
  retention_in_days = 7

  tags = {
    Project     = "streamingapp-capstone"
    Environment = "staging"
    ManagedBy   = "Terraform"
  }
}

resource "aws_cloudwatch_log_group" "jenkins" {
  name              = "/streamingapp-capstone/staging/jenkins"
  retention_in_days = 7

  tags = {
    Project     = "streamingapp-capstone"
    Environment = "staging"
    ManagedBy   = "Terraform"
  }
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