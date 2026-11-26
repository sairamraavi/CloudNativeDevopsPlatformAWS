resource "aws_eks_addon" "metrics_server" {
  cluster_name  = module.eks.cluster_name
  addon_name    = "metrics-server"
  addon_version = "v0.9.0-eksbuild.14"

  resolve_conflicts_on_create = "NONE"
  resolve_conflicts_on_update = "PRESERVE"

  tags = {
    Name = "streamingapp-capstone-dev-metrics-server"
  }

  depends_on = [module.eks]
}