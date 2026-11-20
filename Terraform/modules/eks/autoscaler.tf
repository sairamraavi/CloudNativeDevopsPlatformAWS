
locals {
  autoscaler_oidc_host = var.enable_oidc ? trimprefix(
    aws_eks_cluster.this.identity[0].oidc[0].issuer,
    "https://"
  ) : null
}

resource "aws_iam_role" "autoscaler" {
  count = var.enable_oidc ? 1 : 0

  name = "${var.name_prefix}-autoscaler"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.cluster[0].arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.autoscaler_oidc_host}:aud" = "sts.amazonaws.com"
          "${local.autoscaler_oidc_host}:sub" = "system:serviceaccount:kube-system:cluster-autoscaler"
        }
      }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "autoscaler" {
  count = var.enable_oidc ? 1 : 0

  name = "cluster-autoscaling"
  role = aws_iam_role.autoscaler[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "autoscaling:SetDesiredCapacity",
          "autoscaling:TerminateInstanceInAutoScalingGroup"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:ResourceTag/k8s.io/cluster-autoscaler/enabled"                      = "true"
            "aws:ResourceTag/k8s.io/cluster-autoscaler/${aws_eks_cluster.this.name}" = "owned"
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "autoscaling:DescribeAutoScalingGroups",
          "autoscaling:DescribeAutoScalingInstances",
          "autoscaling:DescribeLaunchConfigurations",
          "autoscaling:DescribeScalingActivities",
          "autoscaling:DescribeTags",
          "ec2:DescribeImages",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeLaunchTemplateVersions",
          "ec2:GetInstanceTypesFromInstanceRequirements",
          "eks:DescribeNodegroup"
        ]
        Resource = "*"
      }
    ]
  })
}

# These tags do not depend on OIDC. Preserve them for possible
# future Cluster Autoscaler installation.
resource "aws_autoscaling_group_tag" "autoscaler_enabled" {
  for_each = aws_eks_node_group.this

  autoscaling_group_name = each.value.resources[0].autoscaling_groups[0].name

  tag {
    key                 = "k8s.io/cluster-autoscaler/enabled"
    value               = "true"
    propagate_at_launch = false
  }
}

resource "aws_autoscaling_group_tag" "autoscaler_cluster" {
  for_each = aws_eks_node_group.this

  autoscaling_group_name = each.value.resources[0].autoscaling_groups[0].name

  tag {
    key                 = "k8s.io/cluster-autoscaler/${aws_eks_cluster.this.name}"
    value               = "owned"
    propagate_at_launch = false
  }
}

output "autoscaler_role_arn" {
  value = var.enable_oidc ? aws_iam_role.autoscaler[0].arn : null
}