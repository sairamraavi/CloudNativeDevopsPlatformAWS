resource "aws_cloudwatch_metric_alarm" "eks_node_cpu_high" {
  alarm_name        = "${local.name_prefix}-eks-node-cpu-high"
  alarm_description = "Triggers when average EKS node CPU utilization exceeds 70% for 15 minutes."

  namespace   = "ContainerInsights"
  metric_name = "node_cpu_utilization"
  statistic   = "Average"
  period      = 300

  dimensions = {
    ClusterName = module.eks.cluster_name
  }

  comparison_operator = "GreaterThanThreshold"
  threshold           = 70
  evaluation_periods  = 3
  datapoints_to_alarm = 3

  treat_missing_data = "notBreaching"

  tags = local.common_tags
}
