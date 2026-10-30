resource "aws_eks_addon" "vpc_cni" {
  cluster_name             = aws_eks_cluster.this.name
  addon_name               = "vpc-cni"
  addon_version            = var.addon_versions.vpc_cni
  service_account_role_arn = aws_iam_role.cni.arn

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"
  tags                        = var.tags

  depends_on = [
    aws_iam_role_policy_attachment.cni,
  ]
}
resource "aws_eks_addon" "core" {
  for_each = {
    coredns                = var.addon_versions.coredns
    kube-proxy             = var.addon_versions.kube_proxy
    eks-pod-identity-agent = var.addon_versions.pod_identity_agent
  }

  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = each.key
  addon_version               = each.value
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"

  tags = var.tags
  depends_on = [
    aws_eks_node_group.this,
  ]
}
resource "aws_eks_addon" "ebs_csi" {
  cluster_name  = aws_eks_cluster.this.name
  addon_name    = "aws-ebs-csi-driver"
  addon_version = var.addon_versions.ebs_csi

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"

  tags = var.tags

  depends_on = [
    aws_eks_pod_identity_association.ebs_csi,
    aws_eks_node_group.this,
  ]
}