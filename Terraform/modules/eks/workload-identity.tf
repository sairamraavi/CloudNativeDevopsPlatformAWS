
resource "aws_iam_openid_connect_provider" "cluster" {
  count = var.enable_oidc ? 1 : 0

  url            = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list = ["sts.amazonaws.com"]
  tags           = var.tags
}

locals {
  oidc_provider_host = var.enable_oidc ? trimprefix(
    aws_iam_openid_connect_provider.cluster[0].url,
    "https://"
  ) : null
}

data "aws_iam_policy_document" "cni_assume_role" {
  count = var.enable_oidc ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type = "Federated"
      identifiers = [
        aws_iam_openid_connect_provider.cluster[0].arn
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
  count = var.enable_oidc ? 1 : 0

  name               = "${var.name_prefix}-eks-cni"
  description        = "Dedicated IPV4 VPC CNI role"
  assume_role_policy = data.aws_iam_policy_document.cni_assume_role[0].json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "cni" {
  count = var.enable_oidc ? 1 : 0

  role       = aws_iam_role.cni[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKS_CNI_Policy"
}