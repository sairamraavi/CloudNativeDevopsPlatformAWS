resource "aws_iam_openid_connect_provider" "cluster" {
  url            = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list = ["sts.amazonaws.com"]
  tags           = var.tags
}

locals {
  oidc_provider_host = trimprefix(
    aws_iam_openid_connect_provider.cluster.url, "https://"
  )
}

data "aws_iam_policy_document" "cni_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithIdentity"]

    principals {
      type = "Federated"
      identifiers = [
        aws_iam_openid_connect_provider.cluster.arn
      ]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_host}:sub"
      values   = ["system:serviceaccount:kube-system:aws-node"]
    }
  }
}
resource "aws_iam_role" "cni" {
  name               = "${var.name_prefix}-eks-cni"
  description        = "Dedicated IPV4 VPC CNI role"
  assume_role_policy = data.aws_iam_policy_document.cluster_assume_role.json
  tags               = var.tags
}
resource "aws_iam_role_policy_attachment" "cni" {
  role       = aws_iam_role.cni.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKS_CNI_Policy"
}