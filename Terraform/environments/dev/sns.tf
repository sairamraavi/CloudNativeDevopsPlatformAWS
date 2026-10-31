resource "aws_sns_topic" "eks_alerts" {
  name = "${local.name_prefix}-eks-alerts"

  tags = local.common_tags
}

resource "aws_sns_topic_subscription" "eks_alerts_email" {
  topic_arn = aws_sns_topic.eks_alerts.arn
  protocol  = "email"
  endpoint  = "prashi222ds@gmail.com"
}

output "eks_alerts_sns_topic_arn" {
  description = "SNS topic ARN for EKS CloudWatch alarm notifications."
  value       = aws_sns_topic.eks_alerts.arn
}
