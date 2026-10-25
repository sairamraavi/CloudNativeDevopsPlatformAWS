resource "aws_launch_template" "nodes" {
  name_prefix            = "${var.name_prefix}-nodes-"
  update_default_version = true

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "disabled"
  }
  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = 30
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }
  tag_specifications {
    resource_type = "instance"

    tags = merge(var.tags, {
      Name = "${var.name_prefix}-worker"
    })
  }
  tag_specifications {
    resource_type = "volume"
    tags          = var.tags
  }

  tags = var.tags
}

resource "aws_eks_node_group" "this" {
  for_each = {
    for index, subnet_id in var.private_subnet_ids :
    tostring(index) => subnet_id
  }

  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.name_prefix}-az-${each.key}"
  node_role_arn   = aws_iam_role.nodes.arn
  subnet_ids      = [each.value]
  version         = var.kubernetes_version
  ami_type        = "AL2023_x86_64_STANDARD"
  capacity_type   = "ON_DEMAND"
  instance_types  = var.node_instance_types

  launch_template {
    id      = aws_launch_template.nodes.id
    version = aws_launch_template.nodes.latest_version
  }
  scaling_config {
    min_size     = 1
    desired_size = 1
    max_size     = var.node_max_size_per_az
  }

  update_config {
    max_unavailable = 1
  }
  node_repair_config {
    enabled = true
  }
  labels = {
    workload = "general"
  }
  tags = merge(var.tags, {
    Name = "${var.name_prefix}-az-${each.key}"
  })
  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }

  depends_on = [
    aws_iam_role_policy_attachment.nodes,
    aws_eks_addon.vpc_cni,
  ]
}