locals {
  container_insights_log_groups = toset([
    "/aws/containerinsights/${local.cluster_name}/application",
    "/aws/containerinsights/${local.cluster_name}/dataplane",
    "/aws/containerinsights/${local.cluster_name}/host",
    "/aws/containerinsights/${local.cluster_name}/performance",
  ])
}

resource "aws_cloudwatch_log_group" "container_insights" {
  for_each = local.container_insights_log_groups

  name              = each.value
  retention_in_days = var.log_retention_days
  skip_destroy      = true

  tags = var.tags
}

import {
  for_each = local.container_insights_log_groups

  to = aws_cloudwatch_log_group.container_insights[each.value]
  id = each.value
}
